import AppKit
import EditorKit

/// The sheet for an image paste that cannot happen: "save the document first" (no folder to put the image in yet) or the reason a
/// write failed.
@MainActor
enum PasteImageAlert {
    static func present(_ problem: MarkdownTextView.PasteImageProblem, document: MarkdownDocument?, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch problem {
        case .needsSavedDocument:
            alert.messageText = String(localized: "Save the document first")
            alert.informativeText = String(localized: "Pasted images are saved in an “images” folder next to the document, so the document needs a place on disk first. Nothing was pasted.")
            alert.addButton(withTitle: String(localized: "Save…"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { document?.save(nil) }
            }
        case .failed(let error):
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The image could not be pasted")
            alert.informativeText = message(for: error)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.beginSheetModal(for: window)
        }
    }

    static func message(for error: PasteImageError) -> String {
        switch error {
        case .unreadable: String(localized: "The image on the clipboard could not be read.")
        case .tooLarge: String(localized: "The image is larger than 64 MB.")
        case .notPermitted(let url): String(localized: "This launch may not use \(url.path).")
        case .imagesIsNotAFolder(let url): String(localized: "\(url.path) is a file, not a folder, so the image cannot be saved there.")
        case .io(let error): error.localizedDescription
        }
    }
}
