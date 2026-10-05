import Foundation

/// A text edit made in the preview (PLAN M2, `Web/src/preview/editing.ts`): source `range` (UTF-16, in the text the edit was made
/// on) replaced by `replacement`. `burst` is the page's number for the run of edits it belongs to (counting up within a page load),
/// `base` the render the page showed when that burst began, `seq` this edit's number in the burst (1, 2, ...). `removed`, `before`
/// and `after` are what the page had in `range` and right around it, so a text with the right length but other characters there is
/// not mistaken for the one the edit was made on. `startsStep`: a new undo step (the page's previous edit was elsewhere, in another
/// block, or the caret moved since); otherwise it continues the last typing step, as keystrokes do.
public struct PreviewEdit: Equatable, Sendable {
    public let burst: Int
    public let base: Int
    public let seq: Int
    public let range: NSRange
    public let replacement: String
    public let removed: String
    public let before: String
    public let after: String
    public let startsStep: Bool

    public init(burst: Int, base: Int, seq: Int, range: NSRange, replacement: String, removed: String, before: String, after: String, startsStep: Bool) {
        self.burst = burst
        self.base = base
        self.seq = seq
        self.range = range
        self.replacement = replacement
        self.removed = removed
        self.before = before
        self.after = after
        self.startsStep = startsStep
    }
}

/// Why an edit from the preview was not applied: the page shows the matching hint.
public enum PreviewEditRefusal: String, Error, Sendable {
    /// It types a line break (structure, which the page refuses too).
    case newline
    /// The text is not the one the edit was made on (it moved on, or the characters at the place differ).
    case stale
}

extension String {
    /// The same UTF-16 code units (Swift's `==` compares canonically: "é" and "e\u{301}" are equal there, and offsets into them are not).
    /// The lengths first (constant time for a string bridged from AppKit, which a text view's is); then the bytes when both strings are
    /// native (no copy), else unit by unit (no copy either).
    public func isIdentical(to other: String) -> Bool {
        guard utf16.count == other.utf16.count else { return false }
        let native = utf8.withContiguousStorageIfAvailable { a in
            other.utf8.withContiguousStorageIfAvailable { b in
                a.count == b.count && (a.baseAddress == b.baseAddress || a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0)
            }
        }
        if let native, let same = native { return same }
        return utf16.elementsEqual(other.utf16)
    }
}

/// What the page has been sent and shows, and which preview edits the app may apply.
///
/// Every render is recorded as sent before the call that sends it (`sent`), and as on the page when that call returns (`landed`). The
/// page may report something about a render before that call has returned (an edit, a selection, a checkbox click: its message comes
/// first), so whatever it names is looked up among the renders sent (`text(ofRender:)`), not only the one known to have landed. Once a
/// render has landed, older ones are dropped: the page shows that one or a newer one.
///
/// The page shows each edit at once and sends it; the app applies edit n of a burst only to exactly the text the page had when it
/// made it: edit 1 to the text of the render it names as its base, edit n to the text edit n-1 produced, and only if the editor still
/// holds that text (the caller checks) with the edit's characters in their place. A gap, an edit of another burst, or a text that
/// changed in between (typing in the editor, an undo, a reload) means the page's text is not the app's: the edit is refused and the
/// page shows the app's text again. A render whose text one of the burst's edits produced carries its `mark`, so the page knows which
/// of its edits it contains (and holds back one that does not have all of them yet); the render with the last edit, once it has
/// landed, ends the burst here too.
public struct PreviewEditChain: Sendable {
    public private(set) var burst: Int?
    public private(set) var seq = 0
    public private(set) var text: String?
    /// The texts the burst's last edits produced (seq, text), newest last.
    private var history: [(seq: Int, text: String)] = []
    /// The renders sent to the page and not superseded yet (version, text), newest last; `landed` the newest one known to be on it.
    private var rendered: [(version: Int, text: String)] = []
    private var landedVersion: Int?
    // lazy: at most 8 of each (copies of the text; normally one or two, `landed` drops the rest); a render or an edit older than that
    // is refused and the page shows the app's text again. upgrade = hashes instead of copies if very large documents make it matter.
    private static let kept = 8

    public init() {}

    /// A render of `text` is being sent to the page as `version`.
    public mutating func sent(version: Int, text: String) {
        rendered.append((version, text))
        if rendered.count > Self.kept { rendered.removeFirst() }
    }

    /// The render `version` is on the page (its call returned, the page applied it), carrying `mark`. Renders before it are not
    /// needed any more, and a burst whose last edit it contains is over.
    public mutating func landed(version: Int, mark: (burst: Int, seq: Int)?) {
        rendered.removeAll { $0.version < version }
        landedVersion = version
        if let mark, mark.burst == burst, mark.seq == seq { clearBurst() }
    }

    /// The render last known to be on the page: what the editor's selection is shown on.
    public var displayed: (version: Int, text: String)? {
        guard let landedVersion, let render = rendered.first(where: { $0.version == landedVersion }) else { return nil }
        return (render.version, render.text)
    }

    /// The text of a render sent lately (what the page shows when it names it), nil when it is not one of them.
    public func text(ofRender version: Int) -> String? {
        rendered.last(where: { $0.version == version })?.text
    }

    /// The text `edit` must be applied to, or why it must be refused.
    public func expectedText(for edit: PreviewEdit) -> Result<String, PreviewEditRefusal> {
        if containsNewline(edit.replacement) { return .failure(.newline) }
        if edit.seq == 1 {
            guard let text = text(ofRender: edit.base) else { return .failure(.stale) }
            return .success(text)
        }
        guard let burst, let text, burst == edit.burst, seq == edit.seq - 1 else { return .failure(.stale) }
        return .success(text)
    }

    /// `edit` was applied and gave `result`.
    public mutating func accept(_ edit: PreviewEdit, result: String) {
        if edit.seq == 1 || burst != edit.burst { history = [] }
        burst = edit.burst
        seq = edit.seq
        text = result
        history.append((edit.seq, result))
        if history.count > Self.kept { history.removeFirst() }
    }

    /// `edit` was refused. The burst's chain goes (later edits of it cannot fit any more); a refusal of an edit of an earlier burst
    /// (bursts count up) leaves a later one alone.
    public mutating func refused(_ edit: PreviewEdit) {
        if let burst, edit.burst < burst { return }
        clearBurst()
    }

    public mutating func reset() {
        self = PreviewEditChain()
    }

    private mutating func clearBurst() {
        burst = nil
        seq = 0
        text = nil
        history = []
    }

    /// What a render of `text` tells the page: the burst and the number of its last edit `text` is the result of.
    public func mark(for text: String) -> (burst: Int, seq: Int)? {
        guard let burst, let entry = history.last(where: { $0.text.isIdentical(to: text) }) else { return nil }
        return (burst, entry.seq)
    }

    /// `edit` fits `text` (the text it was made on): its range lies inside, neither end splits a surrogate pair, the characters in it
    /// and right around it are the ones the page had there, and it types no line break.
    public static func fits(_ edit: PreviewEdit, in text: String) -> Bool {
        let ns = text as NSString
        let r = edit.range
        guard r.location >= 0, r.length >= 0, NSMaxRange(r) <= ns.length, !containsNewline(edit.replacement) else { return false }
        func splits(_ at: Int) -> Bool { at > 0 && at < ns.length && UTF16.isLeadSurrogate(ns.character(at: at - 1)) && UTF16.isTrailSurrogate(ns.character(at: at)) }
        guard !splits(r.location), !splits(NSMaxRange(r)) else { return false }
        // `s` is exactly the units at `from` (an end of `s` past the text's end does not fit)
        func at(_ from: Int, is s: String) -> Bool {
            let units = Array(s.utf16)
            guard from >= 0, from + units.count <= ns.length else { return false }
            return units.indices.allSatisfy { ns.character(at: from + $0) == units[$0] }
        }
        return at(r.location, is: edit.removed) && (edit.removed as NSString).length == r.length
            && at(r.location - (edit.before as NSString).length, is: edit.before)
            && at(NSMaxRange(r), is: edit.after)
    }
}

/// Line breaks as both sides count them (`Web/src/preview/source-map.ts` NEWLINE has the same set).
func containsNewline(_ s: String) -> Bool {
    s.unicodeScalars.contains { [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029].contains($0.value) }
}
