import SwiftUI

/// File menu for workspace windows (the DocumentGroup used to supply it): Open, Open Recent, tabs, and the document
/// commands on the active tab.
///
/// Tab shortcuts: Cmd-Shift-[ / ] and Ctrl-Tab / Ctrl-Shift-Tab step through tabs, Ctrl-1...9 jump to one. Cmd-1...6
/// stay the heading shortcuts (a menu cannot bind one key to two commands depending on focus), so a tab number needs Control.
struct FileCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    private let recents = WorkspaceRegistry.shared.recents

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Document…") { WorkspaceRegistry.shared.showNewDocumentPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open…") { WorkspaceRegistry.shared.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Folder…") { WorkspaceRegistry.shared.showOpenFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { WorkspaceRegistry.shared.open([url]) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }.disabled(recents.urls.isEmpty)
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { workspace?.closeActiveTab() }
                .keyboardShortcut("w")
                .disabled(workspace == nil)
            // Cmd-Shift-W leaves workspace mode (back to browsing); outside a workspace it is the usual Close Window.
            if workspace?.sidebar.isWorkspace == true {
                Button("Close Workspace") { workspace?.sidebar.closeWorkspace() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            } else {
                Button("Close Window") { workspace?.closeWindow() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workspace == nil)
            }
            Divider()
            Button("Save") { workspace?.save() }
                .keyboardShortcut("s")
                .disabled(workspace?.activeDocument == nil)
            Button("Save As…") { workspace?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(workspace?.activeDocument == nil)
            Button("Duplicate…") { workspace?.duplicateDocument() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace?.activeDocument == nil)
            Button("Rename…") { workspace?.renameDocument() }
                .disabled(workspace?.activeDocument == nil)
            Button("Move To…") { workspace?.moveDocument() }
                .disabled(workspace?.activeDocument == nil)
            Menu("Revert To") {
                Button("Last Saved Version") { workspace?.revertToSaved() }
                Button("Browse All Versions…") { workspace?.browseVersions() }
            }
            .disabled(workspace?.activeDocument == nil)
        }
    }
}

/// Window menu: switching tabs.
struct TabCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Next Tab") { workspace?.controller.select(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace?.controller.select(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { workspace?.controller.select(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { workspace?.controller.select(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") { workspace?.controller.select(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .control)
                }
            }
        }
    }
}
