import AppKit
import EditorKit
import MarkdownCore

/// How window-level UI (toolbar, menus) reaches the editor `EditorPane` creates.
@MainActor
final class EditorHandle {
    weak var textView: MarkdownTextView?

    /// The user moved the selection in the editor (it has the focus): the preview shows the same range (two-way selection).
    var onSelectionChange: ((NSRange) -> Void)?

    func perform(_ command: MarkdownCommand) {
        guard let textView else { return }
        textView.perform(command)
        textView.window?.makeFirstResponder(textView)  // a toolbar click must not leave focus elsewhere
    }

    /// Caret to the start of `line` (0-based) and scrolled there; focus follows only when the editor is on screen.
    func goTo(line: Int, focus: Bool) {
        guard let textView else { return }
        textView.goTo(line: line)
        if focus { textView.window?.makeFirstResponder(textView) }
    }

    // MARK: Search results

    /// A result waiting for its file to be on screen (`RevealTracker`; `EditorPane` reports which document the editor shows).
    private var tracker = RevealTracker()

    /// Selects the match at `line` (0-based) of the file `key` as soon as the editor shows that file.
    func reveal(key: String, line: Int, columns: Range<Int>?, focus: Bool) {
        perform(tracker.request(RevealRequest(key: key, line: line, columns: columns, focus: focus)))
    }

    /// `EditorPane`: the editor now shows the document with this file key.
    func documentBound(key: String?) { perform(tracker.bound(key: key)) }

    /// `EditorPane`: the shown document's URL may have changed under it (first save, rename).
    func syncDocumentKey(_ key: String?) { perform(tracker.sync(key: key)) }

    private func perform(_ request: RevealRequest?) {
        guard let request, let textView else { return }
        textView.reveal(line: request.line, columns: request.columns)
        if request.focus { textView.window?.makeFirstResponder(textView) }
    }

    /// A task checkbox was clicked in the preview, which shows `renderedText`: tick or untick `task` in the source. Only when
    /// the editor still holds exactly that text and `task` (the renderer's) still points at a mark (`TaskToggle`), and
    /// as one undo step in the document's undo manager. The edit goes through the text view, which is in the window in every
    /// layout (a hidden pane is only faded out), so the same path serves split and preview-only. Returns the editor's new
    /// text, or nil when nothing was changed.
    func toggleTask(_ task: TaskItem, checked: Bool, renderedText: String) -> String? {
        guard let textView, textView.string == renderedText,
              let edit = TaskToggle.edit(in: renderedText, task: task, checked: checked),
              textView.replaceUndoably(edit.range, with: edit.replacement, actionName: String(localized: "Toggle Task"))
        else { return nil }
        return textView.string
    }

    /// Text edited in the preview (PLAN M2): `edit` made on `expectedText`, which the editor must hold exactly (the page's text and the
    /// editor's agree, so the edit means what the user saw). Typed into the text view as typing there is, so undo and redo work as for
    /// keystrokes in the editor, and the model, the autosave and the next render follow as usual. Returns the editor's new text, or
    /// nil when nothing was changed.
    func applyPreviewEdit(_ edit: PreviewEdit, expectedText: String) -> String? {
        guard let textView, textView.string == expectedText, PreviewEditChain.isApplicable(edit, to: expectedText),
              textView.typeExternally(edit.replacement, replacing: edit.range, startsNewStep: edit.seq == 1)
        else { return nil }
        return textView.string
    }

    /// The preview's selection (a range of `text`, what the preview shows): drawn over the editor's text, not selected. Only while the
    /// editor holds that same text and no input method is composing; nil clears it.
    func showPeerHighlight(_ range: NSRange?, text: String) {
        guard let textView else { return }
        guard let range, range.length > 0, !textView.hasMarkedText(), textView.string == text else { return textView.clearPeerHighlight() }
        textView.showPeerHighlight([range])
    }

    func clearPeerHighlight() { textView?.clearPeerHighlight() }

    func resignFocus() {
        if let textView, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
}
