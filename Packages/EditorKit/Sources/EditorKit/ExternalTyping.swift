import AppKit

extension MarkdownTextView {
    /// Replaces `range` with `string` the way typing in this view does (PLAN M2: text edited in the preview). It is one NSTextView
    /// typing step, so edits that follow each other at the caret coalesce into one "Undo Typing" exactly as keystrokes here do, and
    /// an edit somewhere else starts a new one; `startsNewStep` starts one regardless (the first edit of a burst in the preview must
    /// not join the last typing in the editor).
    ///
    /// What the preview showed must be what the source gets, character for character, so neither the typing assistant
    /// (auto-pairing, list continuation: they act only on typing without a replacement range) nor the system's automatic
    /// substitutions (smart quotes and dashes, text replacement, spelling correction, smart insert/delete) take part; the user's
    /// settings for them are put back right after. The visible part of the view does not move.
    ///
    /// Returns false, having changed nothing, while an input method has marked text, when the view is not editable, when `range` is
    /// not inside the text or either end of it falls between the halves of a surrogate pair. Returns false too if the text after the
    /// edit is not the old one with `range` replaced (it never should be; the caller then shows the editor's text as it is).
    @discardableResult
    public func typeExternally(_ string: String, replacing range: NSRange, startsNewStep: Bool) -> Bool {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return false }
        let text = storage.mutableString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else { return false }
        func splitsPair(_ at: Int) -> Bool {
            at > 0 && at < text.length && UTF16.isLeadSurrogate(text.character(at: at - 1)) && UTF16.isTrailSurrogate(text.character(at: at))
        }
        guard !splitsPair(range.location), !splitsPair(NSMaxRange(range)) else { return false }
        let inserted = (string as NSString).length
        let expectedLength = text.length - range.length + inserted

        let saved = (
            quotes: isAutomaticQuoteSubstitutionEnabled, dashes: isAutomaticDashSubstitutionEnabled,
            replacement: isAutomaticTextReplacementEnabled, spelling: isAutomaticSpellingCorrectionEnabled,
            smart: smartInsertDeleteEnabled
        )
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
        defer {
            isAutomaticQuoteSubstitutionEnabled = saved.quotes
            isAutomaticDashSubstitutionEnabled = saved.dashes
            isAutomaticTextReplacementEnabled = saved.replacement
            isAutomaticSpellingCorrectionEnabled = saved.spelling
            smartInsertDeleteEnabled = saved.smart
        }

        let origin = enclosingScrollView?.contentView.bounds.origin
        if startsNewStep { breakUndoCoalescing() }
        // An explicit replacement range: the typing assistant in `insertText` steps aside, NSTextView does the rest as for a keystroke.
        insertText(string, replacementRange: range)
        if let origin, let clip = enclosingScrollView?.contentView, clip.bounds.origin != origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return text.length == expectedLength && text.substring(with: NSRange(location: range.location, length: inserted)) == string
    }
}
