import AppKit

/// Plain-text Markdown editor view, TextKit 2. Never touch the TextKit 1 layout-manager accessor here or anywhere in
/// this package: it silently downgrades the view (guarded by `Scripts/check-module-boundaries.sh`).
@MainActor
public final class MarkdownTextView: NSTextView {
    public var theme: EditorTheme = .default {
        didSet { applyTheme() }
    }

    /// Called when the visible region scrolls or resizes, with `topVisibleLine`. Only computed while set.
    public var onVisibleLineChange: ((Double) -> Void)?

    /// Auto-pairing, list continuation, Tab behaviour and the settings the formatting commands follow.
    public var behavior = EditorBehavior()

    private(set) var highlighter: MarkdownHighlighter?
    /// Set while our own edits go through `insertText`, so the typing assistant does not re-interpret them.
    private var isApplyingEdit = false

    /// A scroll view hosting a TextKit 2 `MarkdownTextView`, configured like `NSTextView.scrollableTextView()`.
    public static func makeScrollView(theme: EditorTheme = .default) -> (scrollView: NSScrollView, textView: MarkdownTextView) {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        assert(textView.textLayoutManager != nil, "editor must be backed by TextKit 2")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Source text: no typographic rewriting.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.theme = theme  // before the highlighter exists: only sets font and colours
        textView.attachHighlighter()
        return (scrollView, textView)
    }

    private func attachHighlighter() {
        do {
            highlighter = try MarkdownHighlighter(textView: self, theme: theme)
        } catch {
            // The grammar ships in the binary; failing here is a build problem, but the editor must stay usable plain.
            assertionFailure("highlighter unavailable: \(error)")
        }
        guard let scrollView = enclosingScrollView else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(visibleContentChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(visibleContentChanged), name: NSView.frameDidChangeNotification, object: scrollView)
    }

    private func applyTheme() {
        font = theme.font
        backgroundColor = theme.background
        insertionPointColor = theme.caret
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes = theme.baseAttributes
        enclosingScrollView?.backgroundColor = theme.background
        // Chrome (scroll bars, find bar) follows the theme, not the system.
        appearance = theme.chromeAppearance
        enclosingScrollView?.appearance = appearance
        highlighter?.setTheme(theme)
    }

    @objc private func visibleContentChanged() {
        highlighter?.visibleContentDidChange()
        onVisibleLineChange?(topVisibleLine)
    }

    // MARK: IME

    // While text is marked (Chinese/Japanese composition) no attributes are written: restyling would end the
    // composition. The highlighter repaints once it ends.
    public override func unmarkText() {
        super.unmarkText()
        highlighter?.compositionDidEnd()
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if !isApplyingEdit, replacementRange.location == NSNotFound, !hasMarkedText(), let typed = string as? String,
           let storage = textStorage,
           let edit = EditingAssistant.typed(typed, in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        highlighter?.compositionDidEnd()
    }

    // MARK: Editing assistance (PLAN 4.3.4). All of it steps aside while an input method has marked text.

    public override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.newline(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    public override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.tab(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertTab(sender)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.backtab(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.backspace(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.deleteBackward(sender)
        }
    }

    /// Run a menu/toolbar formatting command on the current selection (undoable as one step). No-op while an input
    /// method is composing or the view is read-only.
    public func perform(_ command: MarkdownCommand, pasteboard: NSPasteboard = .general) {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return }
        let clipboard = pasteboard.string(forType: .string)
        guard let edit = command.edit(in: storage.mutableString, selection: selectedRange(), clipboard: clipboard, behavior: behavior) else { return }
        applyEdit(edit)
    }

    /// Every programmatic change goes through `insertText`, i.e. `shouldChangeText` / undo registration / the delegate's
    /// `textDidChange`, exactly like typing. A pure caret move (stepping over a closer) touches no text.
    func applyEdit(_ edit: TextEdit) {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            insertText(edit.replacement, replacementRange: edit.range)
        }
        setSelectedRange(edit.selection)
    }

    // MARK: Loading text from outside

    /// Replace the whole text because the model changed behind the editor's back. Keeps the selection where it makes
    /// sense and the scroll position; does not register undo (callers clear the undo stack, as a document revert does).
    public func reloadText(_ text: String) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        let old = string
        guard old != text else { return }
        let selection = selectedRanges.map(\.rangeValue)
        let origin = enclosingScrollView?.contentView.bounds.origin
        string = text
        selectedRanges = selection.map { NSValue(range: ExternalTextSync.remap($0, from: old, to: text)) }
        if let origin, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    // MARK: Scroll sync (lines are 0-based source lines, fractional = progress through the line)

    /// First visible source line plus how far its layout fragment is scrolled past. Source lines, not wrapped rows.
    public var topVisibleLine: Double {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return 0 }
        let y = max(0, visibleRect.minY - textContainerOrigin.y)
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let progress = frame.height > 0 ? min(max((y - frame.minY) / frame.height, 0), 0.999) : 0
        return Double(lineIndex(atOffset: offset)) + progress
    }

    /// 0-based source line holding the insertion point (selection start).
    public var caretLine: Int { lineIndex(atOffset: selectedRange().location) }

    /// 0-based column of the insertion point in characters (grapheme clusters, so CJK and emoji count as one).
    public var caretColumn: Int {
        let text = (textStorage?.string ?? "") as NSString
        let location = min(selectedRange().location, text.length)
        // Lines end at "\n" only, like `lineIndex(atOffset:)`.
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location))
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        return text.substring(with: NSRange(location: lineStart, length: location - lineStart)).count
    }

    /// Puts the caret at the start of `line` (0-based) and scrolls it to the top of the visible area.
    public func goTo(line: Int) {
        setSelectedRange(NSRange(location: offsetOfLine(line), length: 0))
        scroll(toLine: Double(line))
    }

    /// Scroll so that `line` is at the top of the visible area (no animation).
    public func scroll(toLine line: Double) {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let scrollView = enclosingScrollView else { return }
        let whole = max(0, Int(line.rounded(.down)))
        let progress = min(max(line - Double(whole), 0), 0.999)
        let offset = offsetOfLine(whole)
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return }
        // A fragment that was never laid out reports a zero frame; lay out just the target, then let the view adopt the
        // grown content height (otherwise the clip view cannot scroll that far).
        if let end = content.location(location, offsetBy: 1), let target = NSTextRange(location: location, end: end) {
            layout.ensureLayout(for: target)
        }
        layoutSubtreeIfNeeded()
        guard let fragment = layout.textLayoutFragment(for: location) else { return }
        let frame = fragment.layoutFragmentFrame
        let clip = scrollView.contentView
        let target = frame.minY + progress * frame.height + textContainerOrigin.y
        let maxY = max(0, self.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(target, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    // lazy: both scan from the start per call (memchr-speed, <1 ms at 1 MB); cache a line-start table if scroll sync shows up in a profile
    func lineIndex(atOffset offset: Int) -> Int {
        let text = textStorage?.mutableString ?? NSMutableString()
        var count = 0, i = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        let end = min(offset, text.length)
        while i < end {
            let n = min(buffer.count, end - i)
            text.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 0x0A { count += 1 }
            i += n
        }
        return count
    }

    func offsetOfLine(_ line: Int) -> Int {
        guard line > 0 else { return 0 }
        let text = textStorage?.mutableString ?? NSMutableString()
        var seen = 0, i = 0, lastStart = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        while i < text.length {
            let n = min(buffer.count, text.length - i)
            text.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 0x0A {
                seen += 1
                lastStart = i + k + 1
                if seen == line { return lastStart }
            }
            i += n
        }
        return lastStart  // fewer lines than asked for: the last line
    }
}

extension NSTextView {
    /// UTF-16 range of the characters whose layout fragments intersect the visible rect (TextKit 2; nil when there
    /// is no layout yet, e.g. no window).
    var visibleCharacterRange: NSRange? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let rect = visibleRect
        guard !rect.isEmpty else { return nil }
        let top = rect.minY - textContainerOrigin.y, bottom = rect.maxY - textContainerOrigin.y
        let length = textStorage?.length ?? 0
        func offset(of location: NSTextLocation) -> Int { content.offset(from: content.documentRange.location, to: location) }
        let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top))).map { offset(of: $0.rangeInElement.location) } ?? 0
        let end = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bottom))).map { offset(of: $0.rangeInElement.endLocation) } ?? length
        return NSRange(location: min(start, length), length: max(0, min(end, length) - min(start, length)))
    }
}
