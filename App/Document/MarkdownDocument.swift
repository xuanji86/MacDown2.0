import AppKit
import Combine
import MarkdownCore
import Observation
import UniformTypeIdentifiers
import WorkspaceKit

extension Notification.Name {
    /// Posted by a document whose file moved (Rename…, Move To…, Save As, or a move in Finder); `userInfo` has `old` / `new` URLs.
    static let markdownDocumentMoved = Notification.Name("MarkdownDocumentMoved")
}

/// UTF-8 Markdown file. An `NSDocument` that has no window of its own: workspace windows own documents and show the
/// active one (PLAN 4.11, S3). The editor always works on LF text; the original line-ending style and BOM are
/// remembered at read time and restored on save (`MarkdownFile`).
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument, ObservableObject {
    static let markdownType = "net.daringfireball.markdown"
    static let quartoType = "org.quarto.qmd"

    @Published var text = ""
    /// `isDocumentEdited` as a value views and the window's edited dot can follow.
    @Published private(set) var isEdited = false
    let editedFlag = EditedFlag()
    private(set) var lineEnding: LineEnding = .lf
    private(set) var hasBOM = false

    override class var autosavesInPlace: Bool { true }

    // Declared here, not through `NSDocumentClass` in Info.plist: with a document class in the plist AppKit treats the app as
    // document-based and makes a window-less untitled document at launch, which keeps SwiftUI from opening its first window.
    override class var readableTypes: [String] { [markdownType, quartoType] }
    override class var writableTypes: [String] { [markdownType, quartoType] }
    override class func isNativeType(_ type: String) -> Bool { readableTypes.contains(type) }

    /// The document type for a file, by extension (does not depend on Launch Services having registered our declarations).
    static func type(for url: URL) -> String {
        url.pathExtension.lowercased() == "qmd" ? quartoType : markdownType
    }

    override init() {
        super.init()
        _ = undoManager  // created up front so the document is watching it before the first keystroke
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let file = try MarkdownFile.decode(data)
        // Reading and writing run on the main thread: `canConcurrentlyReadDocuments` / `canAsynchronouslyWrite` stay false.
        MainActor.assumeIsolated {
            lineEnding = file.lineEnding
            hasBOM = file.hasBOM
            text = file.text  // on a revert / external reload this reaches the editor through ExternalTextSync
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated { MarkdownFile(text: text, lineEnding: lineEnding, hasBOM: hasBOM).encoded() }
    }

    // MARK: Change tracking

    /// The editor changed the text (typing, paste, a format command, undo). AppKit is meant to notice edits through the
    /// undo manager, but that does not reliably happen for a window-less document (an undo group the text view leaves
    /// open never reaches it), so the document is marked edited explicitly. Idempotent: autosave clears the mark.
    func noteUserEdit() {
        if !isDocumentEdited { updateChangeCount(.changeDone) }
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        publishEdited()
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        publishEdited()
    }

    private func publishEdited() {
        isEdited = isDocumentEdited
        editedFlag.value = isDocumentEdited
    }

    override var fileURL: URL? {
        didSet {
            guard let old = oldValue, let new = fileURL, old.fileKey != new.fileKey else { return }
            NotificationCenter.default.post(name: .markdownDocumentMoved, object: self, userInfo: ["old": old, "new": new])
        }
    }

    // MARK: Sheets

    /// Save prompts, conflict sheets and Rename… attach to the workspace window showing this document.
    override var windowForSheet: NSWindow? {
        WorkspaceRegistry.shared.sheetWindow(for: self) ?? super.windowForSheet
    }
}

/// Observation-friendly mirror of a document's unsaved state (`NSDocument` itself is not observable).
@MainActor @Observable
final class EditedFlag {
    var value = false
}
