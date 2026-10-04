import AppKit
import OSLog
import UniformTypeIdentifiers
import WorkspaceKit

/// The File menu's document commands. They go straight to the active tab's `NSDocument` (the window controller that
/// shares the window puts the document in the responder chain as well, but menu items built in SwiftUI cannot be
/// validated through it).
extension WindowModel {
    /// Cmd-S. Saving pins a preview tab (design: double click, typing, Cmd-S and dragging all pin).
    func save() {
        guard let document = activeDocument, let url = controller.activeURL else { return }
        controller.pin(url)
        document.save(nil)
    }

    func saveAs() { activeDocument?.saveAs(nil) }

    func revertToSaved() { activeDocument?.revertToSaved(nil) }

    /// File > Revert To > Browse All Versions…
    func browseVersions() { activeDocument?.browseVersions(nil) }

    /// File > Move To… and File > Rename…: the Name / Tags / Where popover of the active tab (`WindowModel+Rename.swift`).
    func moveDocument() { if let url = controller.activeURL { beginTabRename(url) } }
    func renameDocument() { moveDocument() }

    /// File > Duplicate…: a copy next to the original (name asked for), opened as a regular tab. A copy is always a
    /// real file, so there is no untitled document.
    func duplicateDocument() {
        guard let document = activeDocument, let url = document.fileURL, let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = String(localized: "\(base) copy") + "." + url.pathExtension
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                try document.data(ofType: document.fileType ?? MarkdownDocument.markdownType).write(to: target)
                WorkspaceRegistry.shared.open([target])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}
