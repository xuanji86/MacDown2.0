import EditorKit
import SwiftUI

/// Format menu (shortcuts follow the original MacDown), Edit > Copy HTML and the View > layout items. All of them act
/// on the focused document window.
struct FormatCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    private func item(_ title: String, _ command: MarkdownCommand) -> some View {
        Button(title) { actions?.editor.perform(command) }
            .disabled(actions?.editorEnabled != true)
    }

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            item("Bold", .bold).keyboardShortcut("b")
            item("Italic", .italic).keyboardShortcut("i")
            item("Underline", .underline).keyboardShortcut("u")
            item("Strikethrough", .strikethrough).keyboardShortcut("x", modifiers: [.command, .shift])
            item("Highlight", .highlight).keyboardShortcut("h", modifiers: [.command, .shift])
            item("Inline Code", .inlineCode).keyboardShortcut("k")
            item("Comment", .comment).keyboardShortcut("/")
            Divider()
            item("Paragraph", .paragraph).keyboardShortcut("0")
            ForEach(1...6, id: \.self) { level in
                item("Heading \(level)", .heading(level)).keyboardShortcut(KeyEquivalent(Character("\(level)")))
            }
            Divider()
            item("Unordered List", .unorderedList).keyboardShortcut("u", modifiers: [.command, .shift])
            item("Ordered List", .orderedList).keyboardShortcut("o", modifiers: [.command, .shift])
            item("Blockquote", .blockquote).keyboardShortcut("b", modifiers: [.command, .shift])
            item("Code Block", .codeBlock).keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
            item("Link", .link).keyboardShortcut("k", modifiers: [.command, .shift])
            item("Image", .image).keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            item("Indent", .indent).keyboardShortcut("]")
            item("Unindent", .outdent).keyboardShortcut("[")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy HTML") { actions?.copyHTML() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            SplitLayoutItems(actions: actions)
            Button(actions?.outlineShown == true ? "隐藏大纲" : "显示大纲") { actions?.toggleOutline() }
                .keyboardShortcut("o", modifiers: [.command, .control])
                .disabled(actions == nil)
            Button("Cycle Editor and Preview") { actions?.cycleLayout() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(actions == nil)
        }
    }
}
