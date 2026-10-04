import EditorKit
import SwiftUI

/// The editing buttons, flat (no macOS 26 glass capsules), in one of two layouts (`ToolbarStyle`, Settings ▸ Editor ▸ Window).
///
/// Minimal (design "P3 Minimal", the default): one compact title-bar row (`NSWindow.toolbarStyle = .unifiedCompact`). Every
/// editing button sits left after the sidebar toggle in groups ~12 pt apart, no dividers; only the layout toggle is at the far
/// right. Groups that do not fit fold into the system's » menu.
///
/// Classic: the original MacDown's toolbar, its own row under the centred title (`.expanded`). Indent, inline styles and
/// headings stay clustered at the left with a small fixed gap, and only the groups after them are spread across the full
/// width by flexible spacers: [indent | inline styles | headings] ~ lists ~ quote, code ~ link, image ~ copy HTML ~ layout.
struct DocumentToolbar: ToolbarContent {
    let actions: WindowActions
    let style: ToolbarStyle

    private var compact: Bool { style == .minimal }

    /// Classic: a group of buttons as one toolbar item. `sharedBackgroundVisibility(.hidden)` is what removes the glass capsule.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some ToolbarContent {
        ToolbarItem { HStack(spacing: 2) { content() }.foregroundStyle(.secondary) }
            .sharedBackgroundVisibility(.hidden)
    }

    /// Minimal: one button per toolbar item, so the system's » menu folds them one at a time from the right and lists each by
    /// name (a group in one item would be listed as its first glyph, "B"). Items sit flush against each other; the last button of
    /// a group carries the ~12 pt that separates it from the next group.
    private func item<Content: View>(gap: Bool = false, @ViewBuilder _ content: () -> Content) -> some ToolbarContent {
        ToolbarItem { content().padding(.trailing, gap ? 12 : 0) }
            .sharedBackgroundVisibility(.hidden)
    }

    /// A toolbar button drawn as `label` (a glyph), named `title` (its tooltip, its accessibility label and, in the system's » menu,
    /// its entry: see `ToolbarStyleGuard`).
    private func button<Glyph: View>(
        _ title: LocalizedStringKey, _ command: MarkdownCommand, shortcut: String, @ViewBuilder label: () -> Glyph
    ) -> some View {
        Button { actions.editor.perform(command) } label: {
            Label { Text(title) } icon: { label().frame(minWidth: compact ? 0 : 22) }.labelStyle(.iconOnly)
        }
            .buttonStyle(ToolbarIconStyle(compact: compact))
            .help(Text(title) + Text(verbatim: " (\(shortcut))"))
            .accessibilityLabel(Text(title))
            .disabled(!actions.editorEnabled)
    }

    private func symbol(_ title: LocalizedStringKey, _ name: String, _ command: MarkdownCommand, shortcut: String) -> some View {
        button(title, command, shortcut: shortcut) { Image(systemName: name).font(.system(size: 15, weight: compact ? .light : .regular)) }
    }

    private func heading(_ level: Int) -> some View {
        Button { actions.editor.perform(.heading(level)) } label: {
            Label {
                Text("Heading \(level)")
            } icon: {
                Text(verbatim: "H\(level)").font(.system(size: compact ? 12 : 14, weight: compact ? .medium : .regular)).frame(minWidth: compact ? 18 : 26)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(ToolbarIconStyle(compact: compact))
        .help(Text("Heading \(level)") + Text(verbatim: " (⌘\(level))"))
        .accessibilityLabel("Heading \(level)")
        .disabled(!actions.editorEnabled)
    }

    private var divider: some View { Divider().frame(height: 14) }

    /// The fixed gap between the left cluster's groups. Measured on the original (maximized, 2000 px capture): the gaps
    /// indent to B and U to H1 are both ~40 px between icon centres, a B-I-U step is ~29 px, so ~1.4 steps; every flexible
    /// gap after H3 is ~315 px (~11 steps) and grows with the window.
    private var clusterGap: some View { Color.clear.frame(width: Self.clusterGapWidth, height: 1) }
    private static let clusterGapWidth: CGFloat = 16

    @ToolbarContentBuilder private var classic: some ToolbarContent {
        classicLeft
        classicRight
    }

    @ToolbarContentBuilder private var classicLeft: some ToolbarContent {
        group {
            symbol("Unindent", "decrease.indent", .outdent, shortcut: "⌘[")
            symbol("Indent", "increase.indent", .indent, shortcut: "⌘]")
            clusterGap
            button("Bold", .bold, shortcut: "⌘B") { Text(verbatim: "B").font(.system(size: 17, weight: .bold)) }
            divider
            button("Italic", .italic, shortcut: "⌘I") { Text(verbatim: "I").font(.system(size: 17, design: .serif)).italic() }
            divider
            button("Underline", .underline, shortcut: "⌘U") { Text(verbatim: "U").font(.system(size: 17)).underline() }
            clusterGap
            heading(1)
            divider
            heading(2)
            divider
            heading(3)
        }
    }

    @ToolbarContentBuilder private var classicRight: some ToolbarContent {
        ToolbarSpacer(.flexible)
        group {
            symbol("Unordered List", "list.bullet", .unorderedList, shortcut: "⇧⌘U")
            symbol("Ordered List", "list.number", .orderedList, shortcut: "⇧⌘O")
        }
        ToolbarSpacer(.flexible)
        group {
            button("Blockquote", .blockquote, shortcut: "⇧⌘B") {
                Text(verbatim: "\u{201C}\u{201D}").font(.system(size: 20, weight: .bold, design: .serif)).italic()
            }
            button("Code Block", .codeBlock, shortcut: "⌥⌘K") { AngleBrackets() }
        }
        ToolbarSpacer(.flexible)
        group {
            symbol("Link", "link", .link, shortcut: "⇧⌘K")
            symbol("Image", "photo", .image, shortcut: "⇧⌘I")
        }
        ToolbarSpacer(.flexible)
        group { copyHTML }
        ToolbarSpacer(.flexible)
        group { layoutControl }
    }

    /// Minimal: one row, left to right, the order of the board: indent | B I U | H1 H2 H3 | lists | quote, code | link, image |
    /// copy HTML ... (flexible space) ... layout. The system folds the items from the right into the » menu.
    @ToolbarContentBuilder private var minimal: some ToolbarContent {
        minimalLeft
        minimalRight
        ToolbarSpacer(.flexible)
        minimalLayout
    }

    @ToolbarContentBuilder private var minimalLeft: some ToolbarContent {
        item { symbol("Unindent", "decrease.indent", .outdent, shortcut: "⌘[") }
        item(gap: true) { symbol("Indent", "increase.indent", .indent, shortcut: "⌘]") }
        item { button("Bold", .bold, shortcut: "⌘B") { Text(verbatim: "B").font(.system(size: 14, weight: .semibold)) } }
        item { button("Italic", .italic, shortcut: "⌘I") { Text(verbatim: "I").font(.system(size: 15, design: .serif)).italic() } }
        item(gap: true) { button("Underline", .underline, shortcut: "⌘U") { Text(verbatim: "U").font(.system(size: 14)).underline() } }
        item { heading(1) }
        item { heading(2) }
        item(gap: true) { heading(3) }
    }

    @ToolbarContentBuilder private var minimalRight: some ToolbarContent {
        item { symbol("Unordered List", "list.bullet", .unorderedList, shortcut: "⇧⌘U") }
        item(gap: true) { symbol("Ordered List", "list.number", .orderedList, shortcut: "⇧⌘O") }
        item {
            button("Blockquote", .blockquote, shortcut: "⇧⌘B") {
                Text(verbatim: "\u{201C}\u{201D}").font(.system(size: 17, weight: .semibold, design: .serif)).italic()
            }
        }
        item(gap: true) { button("Code Block", .codeBlock, shortcut: "⌥⌘K") { AngleBrackets(size: 12) } }
        item { symbol("Link", "link", .link, shortcut: "⇧⌘K") }
        item(gap: true) { symbol("Image", "photo", .image, shortcut: "⇧⌘I") }
        item { copyHTML }
    }

    /// The layout cycle and its presets menu, the two last to fold (`ToolbarStyleGuard` raises their priority).
    @ToolbarContentBuilder private var minimalLayout: some ToolbarContent {
        item { layoutButton }
        item { layoutPresets }
    }

    var body: some ToolbarContent {
        if compact { minimal } else { classic }
    }

    private var copyHTML: some View {
        Button { actions.copyHTML() } label: {
            Label { Text("Copy HTML") } icon: { CopyHTMLIcon(scale: compact ? 0.85 : 1).frame(minWidth: compact ? 0 : 22) }.labelStyle(.iconOnly)
        }
            .buttonStyle(ToolbarIconStyle(compact: compact))
            .help(Text("Copy HTML") + Text(verbatim: " (⌥⌘C)"))
            .accessibilityLabel("Copy HTML")
    }

    /// The icon cycles both / editor only / preview only; the arrow beside it offers the ratio presets.
    /// (A Menu with a primary action loses its split arrow in a toolbar item without a glass background.)
    private var layoutControl: some View {
        HStack(spacing: 0) {
            layoutButton
            layoutPresets
        }
    }

    private var layoutButton: some View {
        Button { actions.cycleLayout() } label: {
            Label {
                Text("Layout")
            } icon: {
                Image(systemName: symbol).font(.system(size: compact ? 15 : 17, weight: compact ? .light : .regular)).frame(minWidth: compact ? 0 : 22)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(ToolbarIconStyle(compact: compact))
        .help(Text("Cycle Editor and Preview") + Text(verbatim: " (⌃⌘L)"))
    }

    private var layoutPresets: some View {
        Menu {
            SplitLayoutItems(actions: actions)
        } label: {
            Label { Text("Layout Presets") } icon: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }.labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(ToolbarIconStyle(compact: compact, narrow: true))
        .menuIndicator(.hidden)
        .help("Layout Presets")
    }

    private var symbol: String {
        switch actions.layout.mode {
        case .both: "rectangle.split.2x1"
        case .editorOnly: "rectangle.lefthalf.inset.filled"
        case .previewOnly: "rectangle.righthalf.inset.filled"
        }
    }
}

/// A flat toolbar button: no capsule, a faint rounded highlight on hover, darker while pressed. Compact (Minimal): 27 x 23 pt, a
/// dimmer glyph that lights up on hover, white ~8.5% highlight, 14% pressed (design "P3 Minimal").
struct ToolbarIconStyle: ButtonStyle {
    var compact = false
    /// The chevron beside the layout icon: half the width.
    var narrow = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering && isEnabled
        if compact {
            configuration.label
                .foregroundStyle(.primary.opacity(lit || configuration.isPressed ? 0.95 : 0.72))
                .frame(minWidth: narrow ? 14 : 27, minHeight: 23)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(configuration.isPressed ? 0.14 : lit ? 0.085 : 0)))
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        } else {
            configuration.label
                .padding(.horizontal, 5)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(configuration.isPressed ? 0.16 : lit ? 0.08 : 0)))
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The original's "< >": two bare angle brackets (SF Symbols only has the one with a slash).
private struct AngleBrackets: View {
    var size: CGFloat = 14
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left").font(.system(size: size, weight: .regular))
            Image(systemName: "chevron.right").font(.system(size: size, weight: .regular))
        }
    }
}

/// The original's Copy HTML icon: a dashed selection frame with a small "</>" tile overlapping its lower left.
private struct CopyHTMLIcon: View {
    var scale: CGFloat = 1
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
        .scaleEffect(scale)
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
