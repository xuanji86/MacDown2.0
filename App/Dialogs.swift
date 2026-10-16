import AppKit

// The app's panels and alerts are sheets on a window when there is one, free-standing otherwise (a launch before any window, a
// window that was closed meanwhile). These are the one place that says so.

extension NSSavePanel {
    /// Shows the panel as a sheet on `window`, or on its own without one. (`NSOpenPanel` is an `NSSavePanel`.)
    func present(on window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window { beginSheetModal(for: window, completionHandler: done) } else { begin(completionHandler: done) }
    }

    func response(on window: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in present(on: window) { continuation.resume(returning: $0) } }
    }
}

extension NSOpenPanel {
    /// A panel that chooses folders (not files).
    static func folderPicker(prompt: String, multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        return panel
    }
}

extension NSAlert {
    /// Shows the alert as a sheet on `window`, or as a modal alert without one; `done` gets the answer either way.
    func present(on window: NSWindow?, done: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window {
            beginSheetModal(for: window, completionHandler: done)
        } else {
            let response = runModal()
            done?(response)
        }
    }
}
