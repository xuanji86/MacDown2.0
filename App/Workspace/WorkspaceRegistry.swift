import AppKit
import Observation
import OSLog
import UniformTypeIdentifiers
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "workspace")

/// The app-wide side of the workspace windows: the one live `MarkdownDocument` per file (shared by every window that
/// shows it), which window a Finder open goes to, and what is written down for the next launch.
@MainActor
final class WorkspaceRegistry: DocumentBackend {
    static let shared = WorkspaceRegistry()
    static let defaultsKey = "workspace.windows"
    /// Open requests that arrive at launch wait this long for SwiftUI's own first window before asking for another one.
    private static let launchGrace = Duration.milliseconds(2000)

    let ledger = DocumentLedger()
    let recents = RecentDocuments()
    private(set) var models: [UUID: WindowModel] = [:]
    /// Saved windows still to be recreated, back-most last (the next window to appear takes the last one).
    private var restoreQueue: [WorkspaceWindowState] = []
    private var pendingURLs: [URL] = []
    private var launchGraceOver = false
    private(set) var isTerminating = false
    /// Filled by the first window (`OpenWindowAction` only exists inside the view tree).
    var openWindow: (() -> Void)?
    /// A close sheet asked for by a window: that window hosts it, whichever window comes first in the list.
    private var sheetHost: [String: UUID] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: .markdownDocumentMoved, object: nil, queue: .main) { note in
            guard let old = note.userInfo?["old"] as? URL, let new = note.userInfo?["new"] as? URL else { return }
            MainActor.assumeIsolated { WorkspaceRegistry.shared.documentMoved(from: old, to: new) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WorkspaceRegistry.shared.persist() }  // the order of the windows is part of the state
        }
    }

    // MARK: Launch

    /// Reads the saved windows; the windows that appear first claim them (`register`).
    func prepareLaunch() {
        restoreQueue = WindowRestoration.decode(AppDefaults.store.data(forKey: Self.defaultsKey))
        Task {
            try? await Task.sleep(for: Self.launchGrace)
            launchGraceOver = true
            // A launch in the background (login item, `open -g`) gets no window from SwiftUI: make the one that is missing.
            if models.isEmpty, !NSApp.windows.contains(where: \.isVisible) { requestWindow() }
        }
    }

    // MARK: Documents (DocumentBackend)

    func document(for url: URL) -> MarkdownDocument? {
        NSDocumentController.shared.documents.lazy.compactMap { $0 as? MarkdownDocument }.first { $0.fileURL?.fileKey == url.fileKey }
    }

    func isDirty(_ url: URL) -> Bool { document(for: url)?.isDocumentEdited ?? false }

    func load(_ url: URL) throws {
        if document(for: url) != nil { return }
        guard AppDefaults.permitsOpening(url) else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.type(for: url))
        NSDocumentController.shared.addDocument(doc)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recents.refresh()
    }

    func confirmClose(_ url: URL, in window: UUID) async -> Bool {
        guard let doc = document(for: url) else { return true }
        sheetHost[url.fileKey] = window
        defer { sheetHost[url.fileKey] = nil }
        return await withCheckedContinuation { continuation in
            let reply = CloseReply(continuation)
            doc.canClose(withDelegate: reply, shouldClose: #selector(CloseReply.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
    }

    func unload(_ url: URL) {
        guard let doc = document(for: url) else { return }
        // close() closes the document's windows too, and a workspace window must outlive its documents.
        for controller in doc.windowControllers { doc.removeWindowController(controller) }
        doc.close()
    }

    func didActivate(_ url: URL?, in window: UUID) {
        guard let model = models[window] else { return }
        sync(model)
    }

    /// Makes the window's current document the one its window controller belongs to, which is what gives the window its
    /// title, proxy icon and the document-level menus (Rename, Move To, Revert To…).
    func sync(_ model: WindowModel) {
        guard let controller = model.windowController else { return }
        let target = model.controller.activeURL.flatMap(document(for:))
        if controller.document !== target {
            (controller.document as? NSDocument)?.removeWindowController(controller)
            target?.addWindowController(controller)
        }
        guard let window = model.window else { return }
        if let target {
            model.editedSink = target.$isEdited.sink { [weak window] in window?.isDocumentEdited = $0 }
        } else {
            model.editedSink = nil
            window.title = "MacDown2"
            window.representedURL = nil
            window.isDocumentEdited = false
        }
    }

    /// Where AppKit puts this document's sheets (save prompt, "changed by another application"). Always a window that is on
    /// screen: with no usable window AppKit falls back to an application-modal alert (`runModal`), a nested event loop
    /// that stalls whoever asked, so a minimized or hidden window is brought back first.
    func sheetWindow(for doc: MarkdownDocument) -> NSWindow? {
        guard let key = doc.fileURL?.fileKey else { return nil }
        let holders = ledger.holders(of: key)
        let window = sheetHost[key].flatMap { models[$0]?.window }
            ?? orderedModels().first { holders.contains($0.controller.id) && $0.window != nil }?.window
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isVisible { window.orderFront(nil) }
        }
        return window
    }

    private func documentMoved(from old: URL, to new: URL) {
        ledger.rekey(old.fileKey, to: new.fileKey)
        for model in models.values {
            model.controller.documentMoved(from: old, to: new)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(new)
        recents.refresh()
    }

    // MARK: Windows

    func register(_ model: WindowModel) {
        guard !model.isRegistered else { return }
        model.isRegistered = true
        models[model.controller.id] = model
        if let saved = restoreQueue.popLast() { model.apply(saved) }
        sync(model)
        persist()
        DispatchQueue.main.async { [self] in
            if !restoreQueue.isEmpty { requestWindow() } else { drainPending() }
        }
    }

    /// The hosting `NSWindow` exists: give it its window controller and its close review.
    func attach(_ window: NSWindow, to model: WindowModel) {
        guard model.window !== window else { return }
        model.window = window
        let controller = NSWindowController(window: window)
        model.windowController = controller
        let closeGuard = WindowCloseGuard(model: model, original: window.delegate)
        model.closeGuard = closeGuard
        window.delegate = closeGuard
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { if let model { WorkspaceRegistry.shared.windowClosed(model) } }
        }
        sync(model)
    }

    private func windowClosed(_ model: WindowModel) {
        model.controller.detach()
        model.windowController = nil
        model.editedSink = nil
        models[model.controller.id] = nil
        persist()
    }

    /// Front to back; windows that are not on screen yet come last.
    func orderedModels() -> [WindowModel] {
        let ordered = NSApp.orderedWindows.compactMap { window in models.values.first { $0.window === window } }
        return ordered + models.values.filter { m in !ordered.contains { $0 === m } }
    }

    func persist() {
        guard !isTerminating else { return }
        AppDefaults.store.set(WindowRestoration.encode(orderedModels().map(\.state)), forKey: Self.defaultsKey)
    }

    /// A new workspace window: through `openWindow` once a window has handed it over; before that (a launch in the
    /// background gets no window from SwiftUI) by running SwiftUI's own File > New Window item.
    private func requestWindow() {
        if let openWindow { openWindow(); return }
        let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.items.contains(where: Self.isNewWindowItem) }
        if let fileMenu, let item = fileMenu.items.first(where: Self.isNewWindowItem) { fileMenu.performActionForItem(at: fileMenu.index(of: item)) }
    }

    private static func isNewWindowItem(_ item: NSMenuItem) -> Bool { item.keyEquivalent == "n" && item.keyEquivalentModifierMask == .command }

    // MARK: Opening files

    /// Finder double click, Dock drop, Cmd-O, Open Recent: tabs in the frontmost window, a new window when there is none.
    func open(_ urls: [URL]) {
        let urls = urls.filter(AppDefaults.permitsOpening)
        if urls.isEmpty { return }
        if models.isEmpty || !restoreQueue.isEmpty {  // launching: the windows are still coming
            pendingURLs += urls
            if launchGraceOver, models.isEmpty { requestWindow() }
            return
        }
        let snapshots = orderedModels().map { WindowSnapshot(id: $0.controller.id, openKeys: $0.controller.openKeys) }
        guard let plan = OpenRouter.plan(opening: urls, windows: snapshots) else { return }
        switch plan.target {
        case .window(let id): if let model = models[id] { perform(plan.urls, in: model) }
        case .newWindow: pendingURLs += plan.urls; requestWindow()
        }
    }

    private func drainPending() {
        guard !pendingURLs.isEmpty, restoreQueue.isEmpty, let front = orderedModels().first else { return }
        let urls = pendingURLs
        pendingURLs = []
        guard let plan = OpenRouter.plan(opening: urls, windows: [WindowSnapshot(id: front.controller.id, openKeys: front.controller.openKeys)]) else { return }
        perform(plan.urls, in: front)
    }

    private func perform(_ urls: [URL], in model: WindowModel) {
        var failures: [(URL, any Error)] = []
        for url in urls {
            do { try model.controller.open(url, as: .pinned) } catch { failures.append((url, error)) }
        }
        recents.refresh()
        model.window?.makeKeyAndOrderFront(nil)
        for (url, error) in failures {
            log.error("open \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Could not open “\(url.lastPathComponent)”")
            if let window = model.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    /// File > Open… (Cmd-O).
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown, .quarto]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { [self] response in
            if response == .OK { open(panel.urls) }
        }
        if let window = orderedModels().first?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// File > New Document…: names a file, creates it empty (an existing one is opened as it is) and opens it. Documents
    /// are always files, so there is no untitled state to lose.
    func showNewDocumentPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdown]
        panel.nameFieldStringValue = "Untitled.md"
        panel.prompt = String(localized: "Create")
        let done: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                do { try Data().write(to: url) } catch { NSAlert(error: error).runModal(); return }
            }
            open([url])
        }
        if let window = orderedModels().first?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    // MARK: Quit

    var needsTerminationReview: Bool { NSDocumentController.shared.hasEditedDocuments }

    /// Quitting for sure: from here on windows closing do not change what the next launch restores.
    func beginTermination() {
        persist()
        isTerminating = true
    }

    /// Cmd-Q with unsaved documents: the system review (they are window-less, so the sheets go to `sheetWindow`).
    func reviewForTermination(reply: @escaping @MainActor (Bool) -> Void) {
        persist()
        let delegate = ReviewReply { [self] proceed in
            if proceed { isTerminating = true }
            reply(proceed)
        }
        NSDocumentController.shared.reviewUnsavedDocuments(
            withAlertTitle: nil, cancellable: true, delegate: delegate,
            didReviewAllSelector: #selector(ReviewReply.documentController(_:didReviewAll:contextInfo:)), contextInfo: nil
        )
    }
}

/// Target of `canClose(withDelegate:)`: AppKit does not retain delegates, so the object keeps itself alive until it is called.
@MainActor
private final class CloseReply: NSObject {
    private static var live: [ObjectIdentifier: CloseReply] = [:]
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
        super.init()
        Self.live[ObjectIdentifier(self)] = self
    }

    @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.live[ObjectIdentifier(self)] = nil
        continuation.resume(returning: shouldClose)
    }
}

@MainActor
private final class ReviewReply: NSObject {
    private static var live: [ObjectIdentifier: ReviewReply] = [:]
    private let done: @MainActor (Bool) -> Void

    init(_ done: @escaping @MainActor (Bool) -> Void) {
        self.done = done
        super.init()
        Self.live[ObjectIdentifier(self)] = self
    }

    @objc func documentController(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.live[ObjectIdentifier(self)] = nil
        done(didReviewAll)
    }
}

/// File > Open Recent: the system's list of recent documents, as something a SwiftUI menu can observe.
@MainActor @Observable
final class RecentDocuments {
    private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func refresh() { urls = NSDocumentController.shared.recentDocumentURLs }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
}
