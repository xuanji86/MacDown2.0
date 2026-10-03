import EditorKit
import SwiftUI

/// The original MacDown's toolbar, as macOS 26 glass groups separated by fixed spacers:
/// indent | inline styles | headings | lists | quote, code | link, image | copy HTML | layout.
struct DocumentToolbar: ToolbarContent {
    let actions: WindowActions

    private func command(_ title: String, _ symbol: String, _ command: MarkdownCommand, shortcut: String) -> some View {
        Button { actions.editor.perform(command) } label: { Label(title, systemImage: symbol) }
            .help("\(title) (\(shortcut))")
            .disabled(!actions.editorEnabled)
    }

    private func heading(_ level: Int) -> some View {
        Button { actions.editor.perform(.heading(level)) } label: { Text("H\(level)") }
            .help("Heading \(level) (⌘\(level))")
            .disabled(!actions.editorEnabled)
    }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            command("Unindent", "decrease.indent", .outdent, shortcut: "⌘[")
            command("Indent", "increase.indent", .indent, shortcut: "⌘]")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            command("Bold", "bold", .bold, shortcut: "⌘B")
            command("Italic", "italic", .italic, shortcut: "⌘I")
            command("Underline", "underline", .underline, shortcut: "⌘U")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            ControlGroup {  // text-only buttons would each get their own glass bubble
                heading(1)
                heading(2)
                heading(3)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            command("Unordered List", "list.bullet", .unorderedList, shortcut: "⇧⌘U")
            command("Ordered List", "list.number", .orderedList, shortcut: "⇧⌘O")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            command("Blockquote", "text.quote", .blockquote, shortcut: "⌘'")
            command("Code Block", "chevron.left.forwardslash.chevron.right", .codeBlock, shortcut: "⌥⌘K")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            command("Link", "link", .link, shortcut: "⌘K")
            command("Image", "photo", .image, shortcut: "⇧⌘I")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { actions.copyHTML() } label: { Label("Copy HTML", systemImage: "doc.on.clipboard") }
                .help("Copy HTML (⌥⌘C)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            // Click cycles both / editor only / preview only; the arrow offers the ratio presets.
            Menu {
                SplitLayoutItems(actions: actions)
            } label: {
                Label("Layout", systemImage: symbol)
            } primaryAction: {
                actions.cycleLayout()
            }
            .help("Cycle Editor and Preview (⌃⌘L)")
        }
    }

    private var symbol: String {
        switch actions.layout.mode {
        case .both: "rectangle.split.2x1"
        case .editorOnly: "rectangle.lefthalf.inset.filled"
        case .previewOnly: "rectangle.righthalf.inset.filled"
        }
    }
}

/// The five layout presets with a checkmark on the current one; shared by the toolbar menu and the View menu.
struct SplitLayoutItems: View {
    let actions: WindowActions?

    var body: some View {
        let current = actions.flatMap { SplitPreset.matching($0.layout) }
        ForEach(SplitPreset.allCases) { preset in
            Toggle(preset.title, isOn: Binding(get: { preset == current }, set: { _ in actions?.setLayout(preset.layout) }))
                .disabled(actions == nil)
        }
    }
}
