import AppKit
import EditorKit
import MarkdownCore
import SwiftUI

/// Format menu (shortcuts follow the original MacDown), Edit > Copy HTML and the View > layout items. All of them act
/// on the focused document window.
struct FormatCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @FocusedValue(\.workspace) private var workspace
    @AppStorage(WindowChromeKey.statusBar, store: AppDefaults.store) private var showsStatusBar = false
    @AppStorage(ViewZoom.key, store: AppDefaults.store) private var zoomPercent = ViewZoom.actualSize

    private func item(_ title: LocalizedStringKey, _ command: MarkdownCommand) -> some View {
        Button(title) { actions?.editor.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(actions?.editorEnabled != true)
    }

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            item("Bold", .bold)
            item("Italic", .italic)
            item("Underline", .underline)
            item("Strikethrough", .strikethrough)
            item("Highlight", .highlight)
            item("Inline Code", .inlineCode)
            item("Comment", .comment)
            Divider()
            item("Paragraph", .paragraph)  // ⌘0 is View > Actual Size
            ForEach(1...6, id: \.self) { level in
                item("Heading \(level)", .heading(level))
            }
            Divider()
            item("Unordered List", .unorderedList)
            item("Ordered List", .orderedList)
            item("Blockquote", .blockquote)
            item("Code Block", .codeBlock)
            item("Insert Page Break", .pageBreak)
            Divider()
            item("Link", .link)
            item("Image", .image)
            Divider()
            item("Indent", .indent)
            item("Unindent", .outdent)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy HTML") { actions?.copyHTML() }
                .keyboardShortcut(.copyHTML)
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
                .keyboardShortcut(.cycleLayout)
                .disabled(actions == nil)
            let statusBarTitle: LocalizedStringKey = showsStatusBar ? "Hide Status Bar" : "Show Status Bar"
            Button(statusBarTitle) { showsStatusBar.toggle() }
            Divider()
            Button("Render Preview") { actions?.renderPreview() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
            // Only for a document with a real render (a .qmd while Quarto's real render is on).
            if let alternate = actions?.alternatePreview {
                Toggle(alternate.title, isOn: Binding(get: { alternate.isOn }, set: { _ in alternate.toggle() }))
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            // One level for the editor font and the preview (global). "+" is ⌘⇧= on a US keyboard; ⌘= zooms in as well (`ZoomInAlias`).
            Button("Zoom In") { zoomPercent = ViewZoom.zoomedIn(from: zoomPercent) }
                .keyboardShortcut("+")
                .disabled(actions == nil || !ViewZoom.canZoomIn(from: zoomPercent))
            Button("Zoom Out") { zoomPercent = ViewZoom.zoomedOut(from: zoomPercent) }
                .keyboardShortcut("-")
                .disabled(actions == nil || !ViewZoom.canZoomOut(from: zoomPercent))
            Button("Actual Size") { zoomPercent = ViewZoom.actualSize }
                .keyboardShortcut("0")
                .disabled(actions == nil || ViewZoom.clamped(zoomPercent) == ViewZoom.actualSize)
        }
    }
}

/// The Format menu's key equivalents: the menu items take them from here, and the toolbar's tooltips show them.
extension MarkdownCommand {
    var shortcut: KeyboardShortcut? {
        switch self {
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .underline: KeyboardShortcut("u")
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .highlight: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .inlineCode: KeyboardShortcut("k")
        case .comment: KeyboardShortcut("/")
        case .paragraph: KeyboardShortcut("0", modifiers: [.command, .option])  // ⌘0 is View > Actual Size
        case .heading(let level): KeyboardShortcut(KeyEquivalent(Character("\(level)")))
        case .unorderedList: KeyboardShortcut("u", modifiers: [.command, .shift])
        case .orderedList: KeyboardShortcut("o", modifiers: [.command, .shift])
        case .blockquote: KeyboardShortcut("b", modifiers: [.command, .shift])
        case .codeBlock: KeyboardShortcut("k", modifiers: [.command, .option])
        case .pageBreak: nil
        case .link: KeyboardShortcut("k", modifiers: [.command, .shift])
        case .image: KeyboardShortcut("i", modifiers: [.command, .shift])
        case .indent: KeyboardShortcut("]")
        case .outdent: KeyboardShortcut("[")
        }
    }
}

extension KeyboardShortcut {
    static let copyHTML = KeyboardShortcut("c", modifiers: [.command, .option])
    static let cycleLayout = KeyboardShortcut("l", modifiers: [.command, .control])

    /// As menus write it: modifiers in the system's order (⌃⌥⇧⌘), then the key.
    var label: String {
        let marks: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + String(key.character).uppercased()
    }
}

/// ⌘= zooms in too: on a US keyboard "+" is ⌘⇧=, and a menu item has one key equivalent (SwiftUI cannot keep a hidden second one).
/// Performs the View ▸ Zoom In item itself, so it is as enabled and as disabled as the menu says.
@MainActor
enum ZoomInAlias {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mine = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "="
            guard mine, MainActor.assumeIsolated({ performZoomIn() }) else { return event }
            return nil
        }
    }

    private static func performZoomIn() -> Bool {
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            guard let index = menu.items.firstIndex(where: { $0.keyEquivalent == "+" }) else { continue }
            menu.update()  // SwiftUI sets the state of its items when the menu is shown or asked; ask
            guard menu.items[index].isEnabled else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        return false
    }
}
