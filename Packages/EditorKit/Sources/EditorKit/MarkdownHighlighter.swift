import AppKit
import ExtensionAPI
import Neon
import SwiftTreeSitter

/// Glue between a `MarkdownTextView`'s text storage, the tree-sitter engine and Neon's `Highlighter` (which only
/// schedules: it tracks which ranges are valid, prioritises the visible ones, and requests tokens chunk by chunk).
/// Attributes are written into the `NSTextStorage` (never TextKit 2 rendering attributes, PLAN 4.3.1), batched per
/// chunk by this class rather than through Neon's per-token `TextSystemInterface` calls.
@MainActor
final class MarkdownHighlighter {
    private let textView: NSTextView
    private let storage: NSTextStorage
    private let engine: MarkdownHighlightEngine
    private var scheduler: Highlighter!
    private var observer: NSObjectProtocol?

    private(set) var theme: EditorTheme

    /// A document flavor's regex overlay (PLAN 4.3.3), painted over the tree-sitter tokens of every chunk styled.
    private(set) var decorator: DecorationProvider?

    /// Text as the tree-sitter tree last saw it: the "old" side of the next edit's start/end points.
    private var lastText: NSString = ""
    /// Text the point transformer reads from (old text for `willChangeContent`, new text for `didChangeContent`).
    private var pointSource: NSString = ""

    /// Ranges (current coordinates) still to invalidate; flushed on the next main-queue turn because styling must
    /// not run inside `NSTextStorage`'s processEditing.
    private var pendingInvalidation = IndexSet()
    private var flushScheduled = false
    /// A chunk was refused while an IME composition was in flight; repaint when it ends.
    private(set) var needsRepaintAfterComposition = false

    init(textView: NSTextView, theme: EditorTheme) throws {
        guard let storage = textView.textStorage else { preconditionFailure("text view has no storage") }
        self.textView = textView
        self.storage = storage
        self.theme = theme

        // `self` is not fully initialised yet; the closure reads it through a box set right after.
        let box = Box()
        engine = try MarkdownHighlightEngine(pointForOffset: { box.owner?.point(at: $0) })
        box.owner = self

        engine.textProvider = { [weak storage] range in
            guard let storage, NSMaxRange(range) <= storage.length else { return nil }
            return storage.mutableString.substring(with: range)
        }
        engine.invalidationHandler = { [weak self] set in
            // Neon invokes this synchronously from inside the storage edit; defer.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.invalidate(set) } }
        }

        let interface = ViewInterface(textView: textView)
        scheduler = Highlighter(textInterface: interface, tokenProvider: { [weak self] range, done in
            guard let self else { done(.failure(HighlightError.staleContent)); return }
            self.provideTokens(for: range, done: done)
        })
        scheduler.requestLengthLimit = MarkdownHighlightEngine.synchronousLimit

        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageDidEdit() }
        }

        // Text may already be there (the owner sets it before attaching): feed it as one insertion.
        if storage.length > 0 {
            let text = snapshot()
            send(edit: NSRange(location: 0, length: 0), delta: text.length, newText: text)
        }
        scheduler.invalidate(.all)
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Owner API

    func setTheme(_ theme: EditorTheme) {
        self.theme = theme
        scheduler.invalidate(.all)
    }

    func setDecorator(_ decorator: DecorationProvider?) {
        self.decorator = decorator
        scheduler.invalidate(.all)
    }

    /// The visible region changed (scroll, resize): style whatever newly came into view.
    func visibleContentDidChange() { scheduler.visibleContentDidChange() }

    /// Call when the marked range was committed or discarded.
    func compositionDidEnd() {
        guard needsRepaintAfterComposition else { return }
        needsRepaintAfterComposition = false
        scheduler.invalidate(.all)  // only the visible chunks are styled right away; the rest follows on scroll
    }

    // MARK: Editing

    /// Main-thread time our storage-edit handling took last time (snapshot + tree-sitter hand-off), for the perf test.
    private(set) var lastEditHandling: Duration = .zero

    private func storageDidEdit() {
        guard storage.editedMask.contains(.editedCharacters) else { return }  // our own attribute writes
        let started = ContinuousClock.now
        defer { lastEditHandling = ContinuousClock.now - started }
        let edited = storage.editedRange
        let delta = storage.changeInLength
        send(edit: NSRange(location: edited.location, length: edited.length - delta), delta: delta, newText: snapshot())

        // An edit can restyle its whole paragraph (an unclosed `*` upstream, a code span closing downstream), which
        // tree-sitter's changed-ranges do not report for the inline layer.
        pendingInvalidation.remove(integersIn: Int(edited.location)..<(edited.location + edited.length - delta))
        pendingInvalidation.shift(startingAt: edited.location + edited.length - delta, by: delta)
        pendingInvalidation.insert(range: paragraph(around: edited))
        scheduleFlush()
    }

    private func send(edit oldRange: NSRange, delta: Int, newText: NSString) {
        pointSource = lastText
        engine.willChangeContent(in: oldRange)
        pointSource = newText
        scheduler.didChangeContent(in: oldRange, delta: delta)
        engine.didChangeContent(to: newText, in: oldRange, delta: delta)
        lastText = newText
    }

    /// The blank-line-delimited block around `range`, capped.
    // lazy: ±4096 UTF-16 units; a larger paragraph keeps stale inline styling past the cap until it scrolls back in
    private func paragraph(around range: NSRange) -> NSRange {
        let text = storage.mutableString
        let cap = 4096
        var start = max(0, range.location - 1), end = min(text.length, NSMaxRange(range) + 1)
        let lower = max(0, range.location - cap), upper = min(text.length, NSMaxRange(range) + cap)
        let before = text.range(of: "\n\n", options: .backwards, range: NSRange(location: lower, length: max(0, start - lower)))
        start = before.location == NSNotFound ? lower : before.location
        let after = text.range(of: "\n\n", range: NSRange(location: end, length: max(0, upper - end)))
        end = after.location == NSNotFound ? upper : NSMaxRange(after)
        return NSRange(location: start, length: end - start)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { [self] in
            flushScheduled = false
            let set = pendingInvalidation
            pendingInvalidation = IndexSet()
            invalidate(set)
        } }
    }

    private func invalidate(_ set: IndexSet) {
        if textView.hasMarkedText() {
            needsRepaintAfterComposition = true
            return
        }
        scheduler.invalidate(.set(set.intersection(IndexSet(integersIn: 0..<storage.length))))
    }

    // MARK: Tokens -> attributes

    func provideTokens(for range: NSRange, done: @escaping (Result<TokenApplication, Error>) -> Void) {
        if textView.hasMarkedText() {
            needsRepaintAfterComposition = true
            done(.failure(HighlightError.markedText))
            return
        }
        engine.tokens(in: range) { [weak self] result in
            guard let self else { return done(.failure(HighlightError.staleContent)) }
            switch result {
            case .failure(let error): done(.failure(error))
            case .success(let tokens):
                // Composition may have started while an asynchronous query ran.
                guard !textView.hasMarkedText() else {
                    needsRepaintAfterComposition = true
                    return done(.failure(HighlightError.markedText))
                }
                let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
                apply(tokens, in: clamped)
                done(.success(TokenApplication(tokens: [], range: clamped, action: .apply)))
            }
        }
    }

    private func apply(_ tokens: [HighlightToken], in range: NSRange) {
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: range)
        for token in tokens {
            guard let style = theme.tokens[token.kind] else { continue }
            paint(style, in: token.range)
        }
        if let decorator { applyDecorations(decorator, in: range) }
        storage.endEditing()
    }

    private func paint(_ style: TokenStyle, in range: NSRange) {
        if let color = style.color { storage.addAttribute(.foregroundColor, value: color, range: range) }
        if style.underline { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        if style.strikethrough { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        if style.bold || style.italic || style.fontScale != nil {
            // Traits accumulate over nested tokens (emphasis inside strong), so derive from the current font per run.
            // The size is absolute (body size x scale), not compounded, so restyling a chunk twice gives the same font.
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                var font = (value as? NSFont) ?? theme.font
                if let scale = style.fontScale { font = NSFont(descriptor: font.fontDescriptor, size: theme.font.pointSize * scale) ?? font }
                storage.addAttribute(.font, value: font.adding(bold: style.bold, italic: style.italic), range: run)
            }
        }
    }

    /// The flavor sees whole lines (a chunk may start mid-line); what it returns is clipped back to the chunk, whose
    /// attributes were just reset, so the overlay is rebuilt with every restyle and never goes stale.
    // lazy: lines longer than 16K UTF-16 units get no overlay (a chunk would hand the flavor the whole line again and again)
    private func applyDecorations(_ decorate: DecorationProvider, in range: NSRange) {
        let text = storage.mutableString
        let lineRange = text.lineRange(for: range)
        guard lineRange.length <= 16_384 else { return }
        let block = text.substring(with: lineRange)
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        if block.hasSuffix("\n") { lines.removeLast() }  // the empty piece after the final newline
        guard !lines.isEmpty else { return }
        let firstLine = Point.at(utf16Offset: lineRange.location, in: text).map { Int($0.row) } ?? 0
        var starts: [Int] = []
        var offset = lineRange.location
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        for span in decorate(lines, firstLine) {
            let i = span.line - firstLine
            guard starts.indices.contains(i), span.columns.lowerBound >= 0, !span.columns.isEmpty,
                  let kind = TokenKind(rawValue: span.token), let style = theme.tokens[kind] else { continue }
            let absolute = NSRange(location: starts[i] + span.columns.lowerBound, length: span.columns.count)
            if let clipped = MarkdownHighlightEngine.clip(absolute, to: range), NSMaxRange(clipped) <= storage.length {
                paint(style, in: clipped)
            }
        }
    }

    // MARK: tree-sitter points

    /// Immutable copy of the text (a memcpy): safe to hand to Neon's background parse.
    private func snapshot() -> NSString { storage.mutableString.copy() as! NSString }

    private func point(at offset: Int) -> Point? { Point.at(utf16Offset: offset, in: pointSource) }

    private final class Box { weak var owner: MarkdownHighlighter? }
}

/// What Neon's `Highlighter` needs to know about the view. Styling does not go through it (see class comment).
@MainActor
private struct ViewInterface: TextSystemInterface {
    let textView: NSTextView
    func clearStyle(in range: NSRange) {}
    func applyStyle(to token: Token) {}
    var length: Int { textView.textStorage?.length ?? 0 }
    var visibleRange: NSRange { textView.visibleCharacterRange ?? NSRange(location: 0, length: min(length, 4096)) }
}

extension NSFont {
    func adding(bold: Bool, italic: Bool) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}

extension Point {
    /// (row, UTF-16 column in bytes) of a UTF-16 offset; nil past the end.
    static func at(utf16Offset offset: Int, in text: NSString) -> Point? {
        guard offset >= 0, offset <= text.length else { return nil }
        // lazy: O(n) per call (two per edit, ~0.3 ms at 1 MB); keep a line-start table when 10 MB+ documents matter
        var row = 0, lineStart = 0, i = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        while i < offset {
            let n = min(buffer.count, offset - i)
            text.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 0x0A { row += 1; lineStart = i + k + 1 }
            i += n
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }
}

