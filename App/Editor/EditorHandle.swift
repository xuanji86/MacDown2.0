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

    func resignFocus() {
        if let textView, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
}
