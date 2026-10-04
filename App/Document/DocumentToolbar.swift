import EditorKit
import SwiftUI

/// The original MacDown's toolbar: its own row under the title (`.windowToolbarStyle(.expanded)` on the scene), as flat
/// icons without macOS 26's glass capsules, the groups spread across the full width by flexible spacers:
/// indent | inline styles | headings | lists | quote, code | link, image | copy HTML | layout.
struct DocumentToolbar: ToolbarContent {
    let actions: WindowActions

    /// A group of buttons as one toolbar item. `sharedBackgroundVisibility(.hidden)` is what removes the glass capsule.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some ToolbarContent {
        ToolbarItem { HStack(spacing: 2) { content() }.foregroundStyle(.secondary) }
            .sharedBackgroundVisibility(.hidden)
    }

    private func button<Label: View>(
        _ title: String, _ command: MarkdownCommand, shortcut: String, @ViewBuilder label: () -> Label
    ) -> some View {
        Button { actions.editor.perform(command) } label: { label().frame(minWidth: 22) }
            .buttonStyle(ToolbarIconStyle())
            .help("\(title) (\(shortcut))")
            .accessibilityLabel(title)
            .disabled(!actions.editorEnabled)
    }

    private func symbol(_ title: String, _ name: String, _ command: MarkdownCommand, shortcut: String) -> some View {
        button(title, command, shortcut: shortcut) { Image(systemName: name).font(.system(size: 15)) }
    }

    private func heading(_ level: Int) -> some View {
        Button { actions.editor.perform(.heading(level)) } label: {
            Text("H\(level)").font(.system(size: 14)).frame(minWidth: 26)
        }
        .buttonStyle(ToolbarIconStyle())
        .help("Heading \(level) (⌘\(level))")
        .accessibilityLabel("Heading \(level)")
        .disabled(!actions.editorEnabled)
    }

    private var divider: some View { Divider().frame(height: 14) }

    var body: some ToolbarContent {
        group {
            symbol("Unindent", "decrease.indent", .outdent, shortcut: "⌘[")
            symbol("Indent", "increase.indent", .indent, shortcut: "⌘]")
        }
        ToolbarSpacer(.flexible)
        group {
            button("Bold", .bold, shortcut: "⌘B") { Text("B").font(.system(size: 17, weight: .bold)) }
            divider
            button("Italic", .italic, shortcut: "⌘I") { Text("I").font(.system(size: 17, design: .serif)).italic() }
            divider
            button("Underline", .underline, shortcut: "⌘U") { Text("U").font(.system(size: 17)).underline() }
        }
        ToolbarSpacer(.flexible)
        group {
            heading(1)
            divider
            heading(2)
            divider
            heading(3)
        }
        ToolbarSpacer(.flexible)
        group {
            symbol("Unordered List", "list.bullet", .unorderedList, shortcut: "⇧⌘U")
            symbol("Ordered List", "list.number", .orderedList, shortcut: "⇧⌘O")
        }
        ToolbarSpacer(.flexible)
        group {
            button("Blockquote", .blockquote, shortcut: "⇧⌘B") {
                Text("\u{201C}\u{201D}").font(.system(size: 20, weight: .bold, design: .serif)).italic()
            }
            button("Code Block", .codeBlock, shortcut: "⌥⌘K") { AngleBrackets() }
        }
        ToolbarSpacer(.flexible)
        group {
            symbol("Link", "link", .link, shortcut: "⇧⌘K")
            symbol("Image", "photo", .image, shortcut: "⇧⌘I")
        }
        ToolbarSpacer(.flexible)
        group {
            Button { actions.copyHTML() } label: { CopyHTMLIcon().frame(minWidth: 22) }
                .buttonStyle(ToolbarIconStyle())
                .help("Copy HTML (⌥⌘C)")
                .accessibilityLabel("Copy HTML")
        }
        ToolbarSpacer(.flexible)
        group {
            // The icon cycles both / editor only / preview only; the arrow beside it offers the ratio presets.
            // (A Menu with a primary action loses its split arrow in a toolbar item without a glass background.)
            HStack(spacing: 0) {
                Button { actions.cycleLayout() } label: { Image(systemName: symbol).font(.system(size: 17)).frame(minWidth: 22) }
                    .buttonStyle(ToolbarIconStyle())
                    .help("Cycle Editor and Preview (⌃⌘L)")
                    .accessibilityLabel("Layout")
                Menu {
                    SplitLayoutItems(actions: actions)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(ToolbarIconStyle())
                .menuIndicator(.hidden)
                .help("Layout Presets")
                .accessibilityLabel("Layout Presets")
            }
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

/// A flat toolbar button: no capsule, a faint rounded highlight on hover, darker while pressed.
struct ToolbarIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.08 : 0))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The original's "< >": two bare angle brackets (SF Symbols only has the one with a slash).
private struct AngleBrackets: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left").font(.system(size: 14, weight: .regular))
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .regular))
        }
    }
}

/// The original's Copy HTML icon: a dashed selection frame with a small "</>" tile overlapping its lower left.
private struct CopyHTMLIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                .frame(width: 13, height: 13).offset(x: 3.5, y: -3.5)
            RoundedRectangle(cornerRadius: 2).fill(.background).frame(width: 13, height: 13).offset(x: -2.5, y: 2.5)
            RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.2).frame(width: 13, height: 13).offset(x: -2.5, y: 2.5)
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 7, weight: .semibold))
                .offset(x: -2.5, y: 2.5)
        }
        .frame(width: 22, height: 22)
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
