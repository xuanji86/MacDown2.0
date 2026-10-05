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
    /// `macdown2 --preview-only` & co. for the pending opens. lazy: one layout for all of them (the last flag wins), not one per file.
    private var pendingLayout: SplitMode?
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
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let key = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                WorkspaceRegistry.shared.persist()  // the order of the windows is part of the state
                // Trees no file system watcher covers (the volume root and its direct children) catch up when their window comes forward.
                WorkspaceRegistry.shared.models.values.first { key != nil && $0.window.map(ObjectIdentifier.init) == key }?.sidebar.refreshUnwatched()
                WorkspaceRegistry.shared.askPendingExternalChanges()
            }
        }
        // Coming back to the app: look at every open file once (a safety net for events that were missed), then ask what waits.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for case let doc as MarkdownDocument in NSDocumentController.shared.documents { doc.externalMonitor?.check() }
                for model in WorkspaceRegistry.shared.models.values { model.sidebar.refreshUnwatched() }
                WorkspaceRegistry.shared.askPendingExternalChanges()
            }
        }
    }

    // MARK: Launch

    /// Reads the saved windows; the windows that appear first claim them (`register`).
    func prepareLaunch() {
        restoreQueue = WindowRestoration.decode(AppDefaults.store.data(forKey: Self.defaultsKey))
        IsolatedTestHooks.scheduleTermination()
        IsolatedTestHooks.scheduleEdit()
        IsolatedTestHooks.scheduleSettings()
        IsolatedTestHooks.scheduleCloses()
        Task {
            try? await Task.sleep(for: Self.launchGrace)
            launchGraceOver = true
            // A launch in the background (login item, `open -g`) gets no window from SwiftUI: make the one that is missing.
            if models.isEmpty, !NSApp.windows.contains(where: \.isVisible) { requestWindow() }
        }
    }

    // MARK: Documents (DocumentBackend)

    /// fileKey → live document. A cache, never the truth: every hit is checked against the document's current key and the
    /// controller's list, so a rename, Save As, close or an open that bypassed `load` just misses and takes the scan (which refills it).
    private let documentIndex = NSMapTable<NSString, MarkdownDocument>.strongToWeakObjects()

    /// Called from SwiftUI bodies (every tab, every redraw): a hit costs one key computation, not one per open document.
    func document(for url: URL) -> MarkdownDocument? {
        let key = url.fileKey
        let open = NSDocumentController.shared.documents
        if let doc = documentIndex.object(forKey: key as NSString), doc.tabURL?.fileKey == key, open.contains(where: { $0 === doc }) { return doc }
        documentIndex.removeAllObjects()
        var found: MarkdownDocument?
        for case let doc as MarkdownDocument in open {
            guard let docKey = doc.tabURL?.fileKey, documentIndex.object(forKey: docKey as NSString) == nil else { continue }
            documentIndex.setObject(doc, forKey: docKey as NSString)
            if docKey == key { found = doc }
        }
        return found
    }

    func makeUntitled() -> URL {
        let taken = Set(NSDocumentController.shared.documents.compactMap { ($0 as? MarkdownDocument).flatMap { $0.fileURL == nil ? $0.untitledNumber : nil } })
        let doc = MarkdownDocument.makeUntitled(number: UntitledNames.firstFree(taken: taken))
        NSDocumentController.shared.addDocument(doc)
        return doc.tabURL!
    }

    /// Where the first save of an untitled document starts: the workspace folder or the folder the sidebar shows in the window
    /// that holds it (an isolated launch: its temp folder); nil = whatever the panel remembers.
    func defaultSaveFolder(for doc: MarkdownDocument) -> URL? {
        let holders = doc.tabURL.map { ledger.holders(of: $0.fileKey) } ?? []
        let model = orderedModels().first { holders.contains($0.controller.id) }
        let folder = model?.sidebar.folders.roots.first ?? model?.sidebar.location.directory
        return folder ?? AppDefaults.isolation?.allowedRoot
    }

    func isPristineUntitled(_ url: URL) -> Bool { url.isUntitled && document(for: url)?.isPristine == true }

    /// Cmd-N: a new untitled tab in the front window; no window yet = a new window (which comes with one).
    func newUntitled() {
        guard let front = orderedModels().first else {
            requestWindow()
            return
        }
        front.controller.newUntitled()
        front.window?.makeKeyAndOrderFront(nil)
    }

    func isDirty(_ url: URL) -> Bool { document(for: url)?.isDocumentEdited ?? false }

    func load(_ url: URL) throws {
        if document(for: url) != nil {
            SidebarStores.shared.noteOpened(url)
            return
        }
        guard AppDefaults.permitsOpening(url) else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.type(for: url))
        NSDocumentController.shared.addDocument(doc)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        SidebarStores.shared.noteOpened(url)
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
        askPendingExternalChanges()
    }

    /// The window that has `doc` as its active tab and is on screen (front to back); nil when there is none.
    func visibleWindow(showing doc: MarkdownDocument) -> NSWindow? {
        guard let key = doc.tabURL?.fileKey else { return nil }
        return orderedModels().first { model in
            model.controller.activeURL?.fileKey == key && model.window.map { $0.isVisible && !$0.isMiniaturized } == true
        }?.window
    }

    /// "Changed on disk" questions that were waiting for their document to be in front.
    func askPendingExternalChanges() {
        for model in orderedModels() { model.activeDocument?.showPendingExternalPrompt() }
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
        guard let key = doc.tabURL?.fileKey else { return nil }
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
        SidebarStores.shared.noteOpened(new)
        recents.refresh()
    }

    // MARK: Windows

    func register(_ model: WindowModel) {
        guard !model.isRegistered else { return }
        model.isRegistered = true
        models[model.controller.id] = model
        let restored = restoreQueue.popLast()
        if let restored { model.apply(restored) }
        sync(model)
        persist()
        DispatchQueue.main.async { [self] in
            if !restoreQueue.isEmpty { requestWindow() } else { drainPending(into: model) }
            blankWindowGetsUntitled(model, restored: restored != nil)
        }
    }

    /// A window with nothing in it (a launch with nothing to restore or open, Cmd-Option-N, the Dock icon with no window) gets an
    /// untitled tab, as the original MacDown does. A workspace window stays as it is: its tree is the way in.
    private func blankWindowGetsUntitled(_ model: WindowModel, restored: Bool) {
        guard WindowLifecycle.newWindowNeedsUntitled(tabs: model.controller.session.tabs.count, isWorkspace: model.sidebar.isWorkspace, pendingOpens: pendingURLs.count, restored: restored),
              models[model.controller.id] != nil else { return }
        model.controller.newUntitled()
        IsolatedTestHooks.typeIntoUntitled(model)
    }

    /// The Dock icon was clicked with no window open: a new one, which comes with a blank untitled tab. false = the system's
    /// own handling (bringing a minimized window back) is what is wanted; true here means a window was asked for instead.
    func reopen() -> Bool {
        guard WindowLifecycle.reopenNeedsWindow(workspaceWindows: models.count, launching: !launchGraceOver) else { return false }
        requestWindow()
        return true
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
        model.sidebar.shutdown()
        model.controller.detach()
        model.windowController = nil
        model.editedSink = nil
        models[model.controller.id] = nil
        persist()
        #if DEBUG
        debugLifetime.info("window closed")
        #endif
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

    /// File > New Window (Cmd-Option-N).
    private static func isNewWindowItem(_ item: NSMenuItem) -> Bool { item.keyEquivalent == "n" && item.keyEquivalentModifierMask == [.command, .option] }

    // MARK: Opening files

    /// Finder double click, Dock drop, Cmd-O, Open Recent: tabs in the frontmost window, a new window when there is none.
    /// A folder (Finder, `macdown2 .`) enters workspace mode (`OpenRouter`).
    func open(_ urls: [URL]) {
        let urls = urls.filter(AppDefaults.permitsOpening)
        if urls.isEmpty { return }
        // The command line's layout flag, left as a hint file by `macdown2` just before it asked LaunchServices to open these.
        let layout = LayoutHints.take(for: urls.map(\.fileKey), in: Self.layoutHintDirectory)
        if models.isEmpty || !restoreQueue.isEmpty {  // launching: the windows are still coming
            pendingURLs += urls
            pendingLayout = layout ?? pendingLayout
            if launchGraceOver, models.isEmpty { requestWindow() }
            return
        }
        route(urls, layout: layout)
    }

    private static var layoutHintDirectory: URL {
        LayoutHints.directory(home: FileManager.default.homeDirectoryForCurrentUser, suite: AppDefaults.isolation?.suiteName)
    }

    private func route(_ urls: [URL], layout: SplitMode?) {
        guard let plan = OpenRouter.plan(opening: urls, windows: orderedModels().map(\.snapshot)) else { return }
        switch plan.target {
        case .window(let id): if let model = models[id] { perform(plan, in: model, layout: layout) }
        case .newWindow: pendingURLs += urls; pendingLayout = layout ?? pendingLayout; requestWindow()
        }
    }

    /// A window has just come up and nothing is left to restore: the pending opens go to the right window by the usual
    /// rules, but when those say "new window" this fresh one is that window (asking for yet another would never end).
    private func drainPending(into model: WindowModel) {
        guard !pendingURLs.isEmpty, restoreQueue.isEmpty else { return }
        let urls = pendingURLs, layout = pendingLayout
        pendingURLs = []
        pendingLayout = nil
        guard let plan = OpenRouter.plan(opening: urls, windows: orderedModels().map(\.snapshot)) else { return }
        switch plan.target {
        case .window(let id): perform(plan, in: models[id] ?? model, layout: layout)
        case .newWindow: perform(plan, in: model, layout: layout)
        }
    }

    /// `layout` is the command line's flag. A blank window (new, or the front one with nothing in it) that a workspace folder opens in
    /// takes the layout that folder last had; the flag beats that, and applies to a window that already had files too.
    private func perform(_ plan: OpenPlan, in model: WindowModel, layout: SplitMode?) {
        let blank = model.controller.openKeys.isEmpty && !model.sidebar.isWorkspace  // a pristine Untitled tab counts as blank (as in OpenRouter)
        if !plan.folders.isEmpty {
            model.sidebar.openFolders(plan.folders)
        }
        model.startLayout(cli: layout, workspace: blank ? plan.folders : [])
        perform(plan.urls, in: model)
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

    /// File > Open Folder… (Cmd-Shift-O): the front window enters workspace mode with the chosen folder(s), replacing the
    /// folders it had; with no window, a new one.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        let done: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK else { return }
            if let front = orderedModels().first {
                front.sidebar.openFolders(panel.urls, replacing: true)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                open(panel.urls)
            }
        }
        if let window = orderedModels().first?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    // MARK: Sidebar file operations

    /// Tabs (in any window) showing `url` or, for a folder, anything inside it.
    private func tabs(under url: URL) -> [(model: WindowModel, tab: URL)] {
        let key = url.fileKey
        return orderedModels().flatMap { model in
            model.controller.session.tabs.filter { $0.id == key || $0.id.hasPrefix(key + "/") }.map { (model, $0.url) }
        }
    }

    /// Closes the tabs showing `url` (or inside it) before it is moved or trashed. false = the user cancelled a save prompt.
    func closeTabs(under url: URL) async -> Bool {
        for (model, tab) in tabs(under: url) where !(await model.controller.close(tab)) { return false }
        return true
    }

    /// Renames a file or folder from the sidebar. An open document moves through `NSDocument.move` (its tabs follow, unsaved
    /// text survives); a folder with open files closes their tabs first and reopens them at the new place.
    func rename(_ url: URL, to typed: String) async throws -> URL {
        // A file keeps its extension (`.md`, `.qmd`) when the typed name has none; a blank name is left to `destination` to refuse.
        let isFolder = OpenRouter.isFolder(url)
        let normalized = RenameName.normalized(typed: typed, current: url.lastPathComponent)
        let name = isFolder || normalized.isEmpty ? typed : normalized
        if let doc = document(for: url) {
            let target = try FileOperations.destination(renaming: url, to: name)
            if target.path == url.path { return url }
            try await doc.move(to: target)
            return target
        }
        guard isFolder else { return try FileOperations.rename(url, to: name) }
        // Refuse a bad or taken name before any tab is closed: closing asks about unsaved text, and a refusal afterwards would
        // leave the tabs gone for nothing.
        if try FileOperations.destination(renaming: url, to: name).path == url.path { return url }
        let affected = tabs(under: url)
        guard await closeTabs(under: url) else {
            reopen(affected)  // the tabs closed before the user cancelled come back
            return url
        }
        let target: URL
        do { target = try FileOperations.rename(url, to: name) } catch {
            reopen(affected)
            throw error
        }
        let oldPrefix = url.fileKey, newPrefix = target.fileKey
        for (model, tab) in affected {
            let moved = URL(filePath: newPrefix + tab.fileKey.dropFirst(oldPrefix.count))
            try? model.controller.open(moved, as: .pinned)
        }
        return target
    }

    /// Opens again the tabs of `affected` that are not open now (a folder rename that did not happen).
    private func reopen(_ affected: [(model: WindowModel, tab: URL)]) {
        for (model, tab) in affected where !model.controller.holds(tab) { try? model.controller.open(tab, as: .pinned) }
    }

    /// The document popover's Name and Where for a saved file: moves the open document to `name` in `folder` through
    /// `NSDocument.move` (the tab, recents, the sidebar and the external-change monitor follow). Refuses a taken name.
    func relocate(_ url: URL, as name: String, into folder: URL) async throws -> URL {
        guard let doc = document(for: url) else { throw CocoaError(.fileNoSuchFile) }
        let target = try FileOperations.destination(moving: url, as: name, into: folder)
        if target.path == url.path { return url }
        try await doc.move(to: target)
        return target
    }

    /// The popover's Save for an untitled document: the first save, under the chosen name in the chosen folder, without the panel
    /// (the tab, recents and the monitor follow through `markdownDocumentMoved`). Refuses a taken name.
    func saveUntitled(_ url: URL, as name: String, into folder: URL) async throws -> URL {
        guard let doc = document(for: url) else { throw CocoaError(.fileNoSuchFile) }
        let target = try FileOperations.destination(newFile: name, in: folder)
        try await doc.save(to: target, ofType: MarkdownDocument.type(for: target), for: .saveAsOperation)
        return target
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
