import AppKit
import OSLog
import UniformTypeIdentifiers
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "workspace")

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

    /// File > Move To…: the system's destination panel.
    func moveDocument() { activeDocument?.move(nil) }

    /// File > Rename…: asks for the new name in a sheet and moves the file; the tab follows.
    func renameDocument() {
        guard let url = activeDocument?.fileURL, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(url.lastPathComponent)”")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != url.lastPathComponent else { return }
            // The sidebar's rename path: it validates the name and refuses a taken one (`NSDocument.move` would replace it).
            Task {
                do { _ = try await WorkspaceRegistry.shared.rename(url, to: name) } catch {
                    log.error("rename failed: \(String(describing: error), privacy: .public)")
                    NSAlert.fileOperation(error, title: String(localized: "Could not rename “\(url.lastPathComponent)”")).beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

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
