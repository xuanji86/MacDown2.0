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

    /// Identity of an untitled document (Cmd-N): its tab is keyed `URL.untitled(untitledID)` until the first save gives it a
    /// file. nil for a document read from a file.
    private(set) var untitledID: UUID?
    private(set) var untitledNumber: Int?
    /// The user has typed into it (even if it is empty again).
    private var hasBeenEdited = false

    static func makeUntitled(number: Int) -> MarkdownDocument {
        let doc = MarkdownDocument()
        doc.untitledID = UUID()
        doc.untitledNumber = number
        doc.fileType = markdownType  // the first save writes Markdown
        return doc
    }

    /// The key of this document's tab: its file, or the made-up untitled URL.
    var tabURL: URL? { fileURL ?? untitledID.map(URL.untitled) }

    /// An untitled document nobody typed into: opening a file replaces it, closing it asks nothing.
    var isPristine: Bool { fileURL == nil && untitledID != nil && !hasBeenEdited && !isDocumentEdited && text.isEmpty }

    override var displayName: String! {
        get { fileURL == nil ? untitledNumber.map(UntitledNames.title) ?? super.displayName : super.displayName }
        set { super.displayName = newValue }
    }

    /// First save: "<first heading>.md" (else "Untitled.md"), Markdown only.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil {
            savePanel.allowedContentTypes = [.markdown]
            savePanel.nameFieldStringValue = UntitledNames.suggestedFileName(for: text)
            if let folder = WorkspaceRegistry.shared.defaultSaveFolder(for: self) { savePanel.directoryURL = folder }
        }
        return super.prepareSavePanel(savePanel)
    }

    override var shouldRunSavePanelWithAccessoryView: Bool { fileURL != nil }

    /// An untitled document's autosave is a draft in ~/Library/Autosave Information, outside every temp folder: an isolated
    /// launch (tests) must not write there.
    override func autosave(withImplicitCancellability implicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        if fileURL == nil, AppDefaults.isIsolated { return completionHandler(nil) }
        super.autosave(withImplicitCancellability: implicitlyCancellable, completionHandler: completionHandler)
    }

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
        hasBeenEdited = true
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
            // A first save turns the untitled key into the file's: the tab, the ledger and the recents follow.
            guard let new = fileURL, let old = oldValue ?? untitledID.map(URL.untitled), old.fileKey != new.fileKey else { return }
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
