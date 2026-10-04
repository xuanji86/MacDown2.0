import AppKit
import Combine
import MarkdownCore
import Observation
import OSLog
import UniformTypeIdentifiers
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "document")

extension Notification.Name {
    /// Posted (object: the document) after a burst of changes in the folder of a document's file: images the preview shows may
    /// have changed.
    static let markdownDocumentFolderChanged = Notification.Name("MarkdownDocumentFolderChanged")

    /// Posted by a document whose file moved (Rename…, Move To…, Save As, or a move in Finder); `userInfo` has `old` / `new` URLs.
    static let markdownDocumentMoved = Notification.Name("MarkdownDocumentMoved")
}

/// Markdown file. An `NSDocument` that has no window of its own: workspace windows own documents and show the
/// active one (PLAN 4.11, S3). The editor always works on LF text; the original encoding, line-ending style and BOM are
/// remembered at read time and restored on save (`MarkdownFile`).
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument, ObservableObject {
    static let markdownType = "net.daringfireball.markdown"
    /// Not declared by the system (checked on macOS 26/27), so Info.plist imports it as a Markdown alias; files are still typed
    /// `markdownType` by extension. Readable only, so Save As never offers it.
    static let publicMarkdownType = "public.markdown"
    static let quartoType = "org.quarto.qmd"

    @Published var text = ""
    /// `isDocumentEdited` as a value views and the window's edited dot can follow.
    @Published private(set) var isEdited = false
    let editedFlag = EditedFlag()
    /// Encoding, line ending and BOM the file is saved back in; shown in the status bar.
    let format = DocumentFormat()
    /// Set only while `reopen(as:)` re-reads the file.
    private var encodingOverride: TextEncoding?

    // External changes (PLAN I-1). What the file on disk held when the text was last read from it or saved to it:
    // the monitor compares the disk with this, so our own saves and a `touch` are not changes.
    private(set) var externalMonitor: ExternalFileMonitor?
    private var lastSynced: ExternalChangeTracker.Disk?
    /// Fingerprint of the bytes `data(ofType:)` produced last; becomes `lastSynced` when that save succeeds.
    private var pendingWrite: FileFingerprint?
    /// The document is marked edited only because its file went missing (so closing asks to save it), not because of typing.
    private var dirtyOnlyBecauseMissing = false
    /// The "changed on disk" sheet while it is up.
    private var externalPrompt: NSAlert?

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
        // While the "changed on disk" question is open, or the file is gone, nothing writes behind the user's back: AppKit
        // would put its own "changed by another application" sheet over ours, and would re-create a deleted file silently.
        // The text stays in memory (and in the edited state); an explicit save, or the answer, brings autosave back.
        if externalPrompt != nil || editedFlag.missing { return completionHandler(nil) }
        super.autosave(withImplicitCancellability: implicitlyCancellable, completionHandler: completionHandler)
    }

    // Declared here, not through `NSDocumentClass` in Info.plist: with a document class in the plist AppKit treats the app as
    // document-based and makes a window-less untitled document at launch, which keeps SwiftUI from opening its first window.
    override class var readableTypes: [String] { [markdownType, publicMarkdownType, quartoType] }
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
        // Reading and writing run on the main thread: `canConcurrentlyReadDocuments` / `canAsynchronouslyWrite` stay false.
        try MainActor.assumeIsolated {
            let file = try encodingOverride.map { try MarkdownFile.decode(data, as: $0) } ?? MarkdownFile.decode(data)
            format.set(file)
            dirtyOnlyBecauseMissing = false
            markSynced(.present(FileFingerprint(data)))
            text = file.text  // on a revert / external reload this reaches the editor through ExternalTextSync
        }
    }

    /// Never writes anything the file's encoding cannot hold: the save fails (the file on disk stays as it was) and the
    /// error offers to switch to UTF-8 and save again.
    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            do {
                let data = try MarkdownFile(text: text, lineEnding: format.lineEnding, encoding: format.encoding, hasBOM: format.hasBOM).encoded()
                pendingWrite = FileFingerprint(data)
                return data
            } catch let MarkdownFile.EncodeError.unrepresentable(encoding, characters) {
                throw SaveEncodingError.make(document: self, encoding: encoding, characters: characters)
            }
        }
    }

    // MARK: Encoding

    /// Read the file from disk again as `encoding` (the status bar's "reopen with encoding"). Refuses with unsaved edits, which a
    /// re-read would discard.
    func reopen(as encoding: TextEncoding) throws {
        guard let url = fileURL else { return }
        guard !isDocumentEdited else { throw SaveEncodingError.reopenNeedsSave }
        encodingOverride = encoding
        defer { encodingOverride = nil }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? Self.markdownType)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadInapplicableStringEncoding.rawValue {
            throw SaveEncodingError.cannotDecode(encoding)
        }
    }

    /// Save as UTF-8 from now on (the file on disk is only rewritten by the next save). The BOM of a UTF-16 file does not carry over.
    func convertToUTF8() {
        guard format.encoding != .utf8 else { return }
        format.encoding = .utf8
        format.hasBOM = false
        updateChangeCount(.changeDone)  // the encoding is part of the document: there is something to save now
    }

    // MARK: Change tracking

    /// The editor changed the text (typing, paste, a format command, undo). AppKit is meant to notice edits through the
    /// undo manager, but that does not reliably happen for a window-less document (an undo group the text view leaves
    /// open never reaches it), so the document is marked edited explicitly. Idempotent: autosave clears the mark.
    func noteUserEdit() {
        hasBeenEdited = true
        dirtyOnlyBecauseMissing = false
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
            MainActor.assumeIsolated { restartExternalMonitor() }  // AppKit sets the URL on the main thread
            // A first save turns the untitled key into the file's: the tab, the ledger and the recents follow.
            guard let new = fileURL, let old = oldValue ?? untitledID.map(URL.untitled), old.fileKey != new.fileKey else { return }
            NotificationCenter.default.post(name: .markdownDocumentMoved, object: self, userInfo: ["old": old, "new": new])
        }
    }

    // MARK: External changes

    /// The user has unsaved edits of their own (a missing file's marker does not count).
    private var hasUserEdits: Bool { isDocumentEdited && !dirtyOnlyBecauseMissing }

    private func markSynced(_ disk: ExternalChangeTracker.Disk) {
        lastSynced = disk
        externalMonitor?.didSync(disk)
        refreshExternalState()
    }

    /// (Re)attaches the monitor to the file the document has now: first read, Save As, a move in Finder.
    private func restartExternalMonitor() {
        externalMonitor?.stop()
        externalMonitor = nil
        guard let url = fileURL else { return }
        let monitor = ExternalFileMonitor(
            url: url, synced: lastSynced,
            isDirty: { [weak self] in self?.hasUserEdits ?? false },
            onAction: { [weak self] action in self?.handleExternal(action) },
            onSettled: { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .markdownDocumentFolderChanged, object: self)
            })
        guard monitor.start() else {
            log.info("not watching \(url.path, privacy: .public): not on a local volume (or no event stream)")
            return
        }
        externalMonitor = monitor
        refreshExternalState()
    }

    /// Everything that depends on the tracker's state: the "file is gone" mark, and the sheet (gone once its question is moot).
    private func refreshExternalState() {
        editedFlag.missing = externalMonitor?.tracker.isMissing ?? false
        if externalMonitor?.tracker.isPrompting != true { dismissExternalPrompt() }
    }

    private func handleExternal(_ action: ExternalChangeTracker.Action) {
        switch action {
        case .none:
            break
        case .reload:
            reloadFromDisk()
        case .prompt:
            showPendingExternalPrompt()
        case .markMissing:
            // The text stays in the editor and the tab stays open. Marking the document edited makes closing ask to save it
            // and lets Save run; saving writes the file again at its old path.
            if !isDocumentEdited {
                dirtyOnlyBecauseMissing = true
                updateChangeCount(.changeDone)
            }
        }
        refreshExternalState()
    }

    /// Reads the file again (a revert: the text reaches the editor through `ExternalTextSync`, which remaps the selection and
    /// keeps the first visible line). Undo history is cleared, as for every revert: the steps recorded against the old text
    /// must not be replayed on the new one.
    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? Self.markdownType)
            dirtyOnlyBecauseMissing = false
            undoManager?.removeAllActions()
        } catch {
            externalMonitor?.promptNotShown()
            guard FileManager.default.fileExists(atPath: url.path) else { return }  // gone again: the next event says so
            log.error("reload of \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            presentError(error)
        }
    }

    /// Asks "keep mine or reload", once, on the window that shows this document. A sheet, not an alert: it never steals focus
    /// from another window or app, and leaves the rest of the app usable. With no window that shows it on screen (another tab is
    /// in front, the window is minimized) the question waits: it comes up when the tab is activated or the app is.
    func showPendingExternalPrompt() {
        guard externalMonitor?.tracker.isPrompting == true, externalPrompt == nil else { return }
        guard let window = WorkspaceRegistry.shared.visibleWindow(showing: self) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(displayName ?? "")” 已被其他程序修改")
        alert.informativeText = String(localized: "这份文档里有未保存的修改。保留我的版本:磁盘上的新内容会在下次保存时被覆盖。从磁盘重新载入:放弃这里未保存的修改。")
        alert.addButton(withTitle: String(localized: "保留我的版本"))
        alert.addButton(withTitle: String(localized: "从磁盘重新载入"))
        alert.buttons[1].hasDestructiveAction = true
        externalPrompt = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { self?.externalPromptAnswered(response, alert) }
        }
        IsolatedTestHooks.answer(alert, on: window)
    }

    private func externalPromptAnswered(_ response: NSApplication.ModalResponse, _ alert: NSAlert) {
        guard externalPrompt === alert else { return }  // dismissed by us: the question was moot
        externalPrompt = nil
        guard externalMonitor?.tracker.isPrompting == true else { return }
        if response == .alertSecondButtonReturn {
            reloadFromDisk()
        } else {
            keepMyVersion()
        }
        refreshExternalState()
    }

    /// The user's text wins. The file on disk as it is now counts as seen: AppKit's own "changed by another application"
    /// check compares against the date it last saw, so that is brought up to date (otherwise the next save would raise it
    /// and ask again). The text is still unsaved; the next save, explicit or autosave (re-armed here), writes it.
    private func keepMyVersion() {
        externalMonitor?.keepMine()
        if let url = fileURL, let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = modified
        }
        updateChangeCount(.changeDone)
    }

    private func dismissExternalPrompt() {
        guard let alert = externalPrompt else { return }
        externalPrompt = nil
        alert.window.sheetParent?.endSheet(alert.window)
    }

    /// A save writes the file (the text now corresponds to what is on disk), whatever the monitor's events say; while it runs
    /// the monitor does not look (it could see the half-done write).
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let writesTheFile = saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation
        pendingWrite = nil
        if writesTheFile { externalMonitor?.isPaused = true }
        super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
            MainActor.assumeIsolated {
                if writesTheFile {
                    externalMonitor?.isPaused = false
                    if error == nil, let written = pendingWrite {
                        dirtyOnlyBecauseMissing = false
                        markSynced(.present(written))
                    }
                    externalMonitor?.check()  // an outside change during the save is still seen
                }
                pendingWrite = nil
            }
            completionHandler(error)
        }
    }

    override func close() {
        externalMonitor?.stop()
        externalMonitor = nil
        dismissExternalPrompt()
        super.close()
    }

    // MARK: Sheets

    /// Save prompts, conflict sheets and Rename… attach to the workspace window showing this document.
    override var windowForSheet: NSWindow? {
        WorkspaceRegistry.shared.sheetWindow(for: self) ?? super.windowForSheet
    }
}

/// The file format a document is saved in, observable so the status bar follows it without observing the text.
@MainActor @Observable
final class DocumentFormat {
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var hasBOM = false

    var label: String { MarkdownFile(lineEnding: lineEnding, encoding: encoding, hasBOM: hasBOM).formatLabel }

    func set(_ file: MarkdownFile) {
        encoding = file.encoding
        lineEnding = file.lineEnding
        hasBOM = file.hasBOM
    }
}

/// Errors of the encoding features, as AppKit presents them (sheet on the document's window).
enum SaveEncodingError {
    static let domain = "io.github.xuanji86.MacDown2.encoding"

    static func make(document: MarkdownDocument, encoding: TextEncoding, characters: [Character]) -> NSError {
        let shown = characters.map { "“\($0)”" }.joined(separator: " ")
        return NSError(domain: domain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "无法以 \(encoding.displayName) 保存:文档里有这种编码表示不了的字符 \(shown)。",
            NSLocalizedRecoverySuggestionErrorKey: "文件没有被改动,也不会丢字。可以改用 UTF-8 保存(它能表示所有字符)。",
            NSLocalizedRecoveryOptionsErrorKey: ["改用 UTF-8 保存", "取消"],
            NSRecoveryAttempterErrorKey: UTF8Recovery(document: document),
        ])
    }

    static let reopenNeedsSave = NSError(domain: domain, code: 2, userInfo: [
        NSLocalizedDescriptionKey: "有未保存的修改,不能重新打开。",
        NSLocalizedRecoverySuggestionErrorKey: "先保存或还原修改,再选择编码。",
    ])

    static func cannotDecode(_ encoding: TextEncoding) -> NSError {
        NSError(domain: domain, code: 3, userInfo: [
            NSLocalizedDescriptionKey: "无法以 \(encoding.displayName) 打开这个文件。",
            NSLocalizedRecoverySuggestionErrorKey: "文件内容在该编码下无效,或读出的文字无法原样写回。文档保持原样。",
        ])
    }

    /// NSError's recovery attempter: "改用 UTF-8 保存" switches the document and saves it again.
    private final class UTF8Recovery: NSObject {
        weak var document: MarkdownDocument?
        init(document: MarkdownDocument) { self.document = document }

        override func attemptRecovery(fromError error: Error, optionIndex: Int) -> Bool {
            guard optionIndex == 0 else { return false }
            DispatchQueue.main.async { [document] in
                MainActor.assumeIsolated {
                    document?.convertToUTF8()
                    document?.save(nil)
                }
            }
            return true
        }
    }
}

/// Observation-friendly mirror of a document's unsaved state (`NSDocument` itself is not observable).
@MainActor @Observable
final class EditedFlag {
    var value = false
    /// The file was deleted or moved away on disk; the text is still here.
    var missing = false
}
