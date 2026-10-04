import AppKit
import OSLog
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "workspace")

/// What the Name / Tags / Where popover is editing: a copy of the tab's document facts that the popover's controls write to
/// and that `WindowModel` applies when the popover ends. The model keeps it (not the popover) so it survives the "Other…" folder
/// panel, which takes the key window and so closes the popover for a moment.
@MainActor @Observable
final class RenameDraft {
    let url: URL
    /// What the file is called now, extension included; an untitled document's is its would-be "Untitled 2.md".
    let currentFileName: String
    let isUntitled: Bool
    let startFolder: URL
    let startTags: [String]
    let workspace: [URL]
    var name: String
    var folder: URL
    var tags: [String]
    /// The "Other…" panel is up: the popover steps aside (observed, so it comes back when this goes false).
    var pickingFolder = false

    init(url: URL, document: MarkdownDocument, workspace: [URL], startFolder fallback: URL?) {
        self.url = url
        isUntitled = url.isUntitled
        currentFileName = isUntitled ? (document.displayName ?? "Untitled") + ".md" : url.lastPathComponent
        name = isUntitled ? (document.displayName ?? "Untitled") : url.lastPathComponent
        let folder = isUntitled ? (fallback ?? FileManager.default.homeDirectoryForCurrentUser) : url.deletingLastPathComponent()
        startFolder = folder
        self.folder = folder
        let tags = isUntitled ? [] : ((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        startTags = tags
        self.tags = tags
        self.workspace = workspace
    }

    /// The "Where:" menu: this file's folder first, then workspace folders, recent documents' folders, Desktop/Documents/Downloads
    /// (a launch that is isolated for testing only offers its own folder).
    var folderChoices: [URL] {
        let recents = NSDocumentController.shared.recentDocumentURLs.map { $0.deletingLastPathComponent() }
        let all = WhereChoices.folders(current: folder, workspace: workspace, recents: recents)
        guard let isolation = AppDefaults.isolation else { return all }
        return all.filter { isolation.allows($0) }
    }
}

extension WindowModel {
    /// A click on the active tab's name, a tab's Rename…, or File > Rename… / Move To…: the popover opens on that tab. The tab is
    /// brought to the front and pinned (a preview tab would be replaced by the next file opened).
    func beginTabRename(_ url: URL) {
        let registry = WorkspaceRegistry.shared
        guard controller.holds(url), let document = registry.document(for: url) else { return }
        controller.activate(url)
        controller.pin(url)
        renameDraft = RenameDraft(url: url, document: document, workspace: sidebar.folders.roots, startFolder: registry.defaultSaveFolder(for: document))
    }

    /// Esc.
    func cancelTabRename() { renameDraft = nil }

    /// The popover went away (a click elsewhere, the window lost the key): a saved file takes what was typed; an untitled one is
    /// not saved by that (its Save button does it). Not while the "Other…" folder panel is up: the popover comes back after it.
    func popoverDismissed() {
        guard let draft = renameDraft, !draft.pickingFolder else { return }
        renameDraft = nil
        if !draft.isUntitled { apply(draft) }
    }

    /// Return, or the Save button.
    func saveRename() {
        guard let draft = renameDraft else { return }
        renameDraft = nil
        apply(draft)
    }

    /// "Other…": a folder panel; the popover opens again with the choice.
    func chooseFolder(for draft: RenameDraft) {
        draft.pickingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = draft.folder
        panel.prompt = String(localized: "Choose")
        let done: (NSApplication.ModalResponse) -> Void = { [self] response in
            if response == .OK, let folder = panel.url, AppDefaults.isolation?.allows(folder) ?? true { draft.folder = folder }
            draft.pickingFolder = false
            renameDraft = draft
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Does what the draft says: rename and/or move through the registry (extension kept, a taken name refused), the first save
    /// for an untitled document, then the Finder tags. A failure shows the usual alert; nothing is half-applied but the tags.
    private func apply(_ draft: RenameDraft) {
        let url = draft.url
        let name = RenameName.normalized(typed: draft.name, current: draft.currentFileName)
        guard !name.isEmpty else { return }
        let changed = name != draft.currentFileName || draft.folder.fileKey != draft.startFolder.fileKey || draft.tags != draft.startTags
        guard draft.isUntitled || changed else { return }
        Task {
            do {
                let registry = WorkspaceRegistry.shared
                let final = draft.isUntitled
                    ? try await registry.saveUntitled(url, as: name, into: draft.folder)
                    : try await registry.relocate(url, as: name, into: draft.folder)
                if draft.tags != draft.startTags { try (final as NSURL).setResourceValue(draft.tags, forKey: .tagNamesKey) }
            } catch {
                log.error("rename failed: \(String(describing: error), privacy: .public)")
                let title = draft.isUntitled ? String(localized: "Could not save “\(name)”") : String(localized: "Could not rename “\(url.lastPathComponent)”")
                let alert = NSAlert.fileOperation(error, title: title)
                if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            }
        }
    }
}
