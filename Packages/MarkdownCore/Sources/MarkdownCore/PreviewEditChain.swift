import Foundation

/// A text edit made in the preview (PLAN M2, `Web/src/preview/editing.ts`): source `range` (UTF-16, in the text the edit was made
/// on) replaced by `replacement`. `base` is the render the page showed when its burst of edits began, `seq` this edit's number in
/// the burst (1, 2, ...).
public struct PreviewEdit: Equatable, Sendable {
    public let base: Int
    public let seq: Int
    public let range: NSRange
    public let replacement: String

    public init(base: Int, seq: Int, range: NSRange, replacement: String) {
        self.base = base
        self.seq = seq
        self.range = range
        self.replacement = replacement
    }
}

/// Which preview edits the app may apply, and what the renders it sends back say about them.
///
/// The page shows each edit at once and sends it; the app applies edit n of a burst only to exactly the text the page had when it
/// made it: edit 1 to the text of the render the page shows (`displayed`), edit n to the text edit n-1 produced, and only if the
/// editor still holds that text (the caller checks). A gap, a different burst, or a text that changed in between (typing in the
/// editor, an undo, a reload) means the page's text is not the app's: the edit is refused, the chain is dropped, and the page shows
/// the app's text again. A render whose text is the chain's latest carries `mark`, so the page knows which of its edits it contains.
public struct PreviewEditChain: Sendable {
    public private(set) var base: Int?
    public private(set) var seq = 0
    public private(set) var text: String?

    public init() {}

    /// The text `edit` must be applied to, or nil when it must be refused.
    public func expectedText(for edit: PreviewEdit, displayed: (version: Int, text: String)?) -> String? {
        if edit.seq == 1 {
            guard let displayed, displayed.version == edit.base else { return nil }
            return displayed.text
        }
        guard let base, let text, base == edit.base, seq == edit.seq - 1 else { return nil }
        return text
    }

    /// `edit` was applied and gave `result`.
    public mutating func accept(_ edit: PreviewEdit, result: String) {
        base = edit.base
        seq = edit.seq
        text = result
    }

    public mutating func reset() {
        self = PreviewEditChain()
    }

    /// What a render of `text` tells the page: the burst and the number of its last edit when `text` is what that edit produced.
    public func mark(for text: String) -> (base: Int, seq: Int)? {
        guard let base, let mine = self.text, mine == text else { return nil }
        return (base, seq)
    }

    /// `edit` fits `text`: its range lies inside, neither end splits a surrogate pair, and it types no line break (a line break is
    /// structure, which the page refuses too).
    public static func isApplicable(_ edit: PreviewEdit, to text: String) -> Bool {
        let units = text.utf16
        let r = edit.range
        guard r.location >= 0, r.length >= 0, r.location + r.length <= units.count else { return false }
        if edit.replacement.contains(where: \.isNewline) { return false }
        func splits(_ at: Int) -> Bool {
            guard at > 0, at < units.count else { return false }
            let before = units[units.index(units.startIndex, offsetBy: at - 1)]
            let after = units[units.index(units.startIndex, offsetBy: at)]
            return UTF16.isLeadSurrogate(before) && UTF16.isTrailSurrogate(after)
        }
        return !splits(r.location) && !splits(r.location + r.length)
    }

    /// `text` with `edit` made (the page computes the same with JavaScript's UTF-16 string operations).
    public static func applying(_ edit: PreviewEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
}
