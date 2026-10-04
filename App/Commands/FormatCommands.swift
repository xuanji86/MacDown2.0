import EditorKit
import SwiftUI

/// Format menu (shortcuts follow the original MacDown), Edit > Copy HTML and the View > layout items. All of them act
/// on the focused document window.
struct FormatCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @FocusedValue(\.workspace) private var workspace
    @AppStorage(WindowChromeKey.statusBar, store: AppDefaults.store) private var showsStatusBar = false

    private func item(_ title: LocalizedStringKey, _ command: MarkdownCommand) -> some View {
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
            item("Insert Page Break", .pageBreak)
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
        CommandGroup(after: .textEditing) {
            Button("Search in Files") { workspace?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            SplitLayoutItems(actions: actions)
            let sidebarTitle: LocalizedStringKey = workspace?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar"
            Button(sidebarTitle) { workspace?.sidebarVisible.toggle() }
                .keyboardShortcut("\\")
                .disabled(workspace == nil)
            Button("Show Outline") { workspace?.showOutline() }
                .keyboardShortcut("o", modifiers: [.command, .control])
                .disabled(workspace == nil)
            Button("Cycle Editor and Preview") { actions?.cycleLayout() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(actions == nil)
            let statusBarTitle: LocalizedStringKey = showsStatusBar ? "Hide Status Bar" : "Show Status Bar"
            Button(statusBarTitle) { showsStatusBar.toggle() }
        }
    }
}
