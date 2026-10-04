import AppKit
import EditorKit

/// How window-level UI (toolbar, menus) reaches the editor `EditorPane` creates.
@MainActor
final class EditorHandle {
    weak var textView: MarkdownTextView?

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

    /// A result waiting for its file to be on screen: opening a tab only changes the window's active document, the editor
    /// swaps its text a moment later (`EditorPane` calls `documentBound`).
    private struct Reveal {
        let key: String
        let line: Int
        let columns: Range<Int>?
        let focus: Bool
    }
    private var pending: Reveal?
    /// File key of the document the editor shows now (nil: untitled or none).
    private var shownKey: String?

    /// Selects the match at `line` (0-based) of the file `key` as soon as the editor shows that file.
    func reveal(key: String, line: Int, columns: Range<Int>?, focus: Bool) {
        pending = Reveal(key: key, line: line, columns: columns, focus: focus)
        applyPending()
    }

    /// `EditorPane`: the editor now shows the document with this file key.
    func documentBound(key: String?) {
        shownKey = key
        applyPending()
        pending = nil  // a result for a file that never came up must not fire on some later tab switch
    }

    private func applyPending() {
        guard let reveal = pending, reveal.key == shownKey, let textView else { return }
        pending = nil
        textView.reveal(line: reveal.line, columns: reveal.columns)
        if reveal.focus { textView.window?.makeFirstResponder(textView) }
    }

    func resignFocus() {
        if let textView, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
}
