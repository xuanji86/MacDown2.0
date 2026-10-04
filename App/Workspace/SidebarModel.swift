import AppKit
import Observation
import OSLog
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "sidebar")

/// One window's Files page: browse mode (favorites / current location / recents) or workspace mode (the trees of the
/// workspace folders), the filter, and the file operations of the right-click menu. Directories are always read off the
/// main thread; `tree` only ever receives finished listings.
@MainActor @Observable
final class SidebarModel {
    /// Workspace folders of this window; none = browse mode.
    private(set) var folders = WorkspaceFolders()
    var showAllFiles = false {
        didSet { if showAllFiles != oldValue { optionsChanged() } }
    }
    var filter = "" {
        didSet { if filter != oldValue { filterChanged() } }
    }
    private(set) var tree = FileTreeModel()
    private(set) var location = CurrentLocation()
    /// Folders whose read has taken longer than 300 ms: they show the skeleton.
    private(set) var skeletons: Set<String> = []
    /// File key the table should select and start renaming / just select, once its row exists.
    var pendingEdit: String?
    var pendingSelect: String?

    @ObservationIgnored let controller: WorkspaceController
    @ObservationIgnored var window: () -> NSWindow? = { nil }
    @ObservationIgnored let stores = SidebarStores.shared
    @ObservationIgnored private let follower = Debouncer(delay: .milliseconds(150))
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var crawl: Task<Void, Never>?
    /// A file made with "New File": opened as a tab once the user has named it.
    @ObservationIgnored private var createdFile: String?

    init(controller: WorkspaceController) { self.controller = controller }

    var isWorkspace: Bool { folders.isActive }
    var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

    static let volumeName: String = {
        (try? URL(filePath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }()

    /// Isolated launches may only look inside their temp folder.
    private func isAllowed(_ url: URL) -> Bool { AppDefaults.isolation?.allows(url) ?? true }

    var canGoUp: Bool { location.parent.map(isAllowed) ?? false }

    func snapshot() -> SidebarSnapshot {
        if isWorkspace { return SidebarContent.workspace(tree: tree, query: filter, skeletons: skeletons) }
        return SidebarContent.browse(
            favorites: stores.favorites, location: location, tree: tree, recents: stores.recents, query: filter,
            skeletons: skeletons, rootTitle: Self.volumeName, canGoUp: canGoUp)
    }

    // MARK: Window state

    func restore(roots: [URL], showAll: Bool) {
        folders = WorkspaceFolders(roots: roots.filter(isAllowed)).existing()
        showAllFiles = showAll
        syncRoots()
    }

    func shutdown() {
        follower.cancel()
        crawl?.cancel()
        watcher?.stop()
        watcher = nil
        generation += 1
    }

    // MARK: Modes

    /// Enters workspace mode, or adds roots when already in it (`replacing` swaps them, as File > Open Folder… does).
    func openFolders(_ urls: [URL], replacing: Bool = false) {
        let allowed = urls.filter(AppDefaults.permitsOpening)
        guard !allowed.isEmpty else { return }
        if replacing { folders.close() }
        for url in allowed { folders.add(url) }
        filter = ""
        syncRoots()
    }

    func closeWorkspace() {
        folders.close()
        filter = ""
        syncRoots()
    }

    // MARK: Current location

    /// The active document changed. Debounced, so flicking through tabs does not re-point the tree on every step.
    func follow(_ documentURL: URL?, immediately: Bool = false) {
        let apply: @MainActor () -> Void = { [self] in
            location.follow(documentURL: documentURL)
            if !isWorkspace { syncRoots() }
        }
        if immediately {
            follower.cancel()
            apply()
        } else {
            follower.submit(apply)
        }
    }

    func navigate(to url: URL) {
        guard isAllowed(url) else { return }
        location.navigate(to: url)
        syncRoots()
    }

    func goUp() {
        if let parent = location.parent { navigate(to: parent) }
    }

    // MARK: Tree

    private func syncRoots() {
        let wanted = isWorkspace ? folders.roots : (location.directory.map { [$0] } ?? [])
        guard wanted.map(\.fileKey) != tree.roots.map(\.fileKey) else {
            loadPending()
            return
        }
        generation += 1
        loading = []
        skeletons = []
        var fresh = FileTreeModel(roots: [], options: FileTreeOptions(showAllFiles: showAllFiles))
        for root in wanted { fresh.addRoot(root, load: false) }
        tree = fresh
        restartWatcher()
        loadPending()
        if isFiltering { startCrawl() }
    }

    private func optionsChanged() {
        generation += 1
        loading = []
        skeletons = []
        tree.setOptions(FileTreeOptions(showAllFiles: showAllFiles), relist: false)
        loadPending()
        if isFiltering { startCrawl() }
    }

    private func filterChanged() {
        if isFiltering { startCrawl() } else { crawl?.cancel() }
    }

    private func loadPending() {
        for directory in tree.expandedDirectories where !tree.isLoaded(directory) { ensureLoaded(directory) }
    }

    func setExpanded(_ url: URL, _ open: Bool) {
        tree.setExpanded(url, open, load: false)
        if open {
            ensureLoaded(url)
            if isFiltering { startCrawl() }
        }
    }

    func toggle(_ url: URL) { setExpanded(url, !tree.isExpanded(url)) }

    /// Reads `directory` in the background unless it is read or being read. The skeleton shows only if it takes > 300 ms.
    private func ensureLoaded(_ directory: URL) {
        let key = directory.fileKey
        guard !tree.isLoaded(directory), loading.insert(key).inserted else { return }
        let generation = generation
        let options = tree.options
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.generation == generation, self.loading.contains(key) else { return }
            self.skeletons.insert(key)
        }
        let allowed = isAllowed(directory)
        Task { [weak self] in
            let listing = await Task.detached(priority: .userInitiated) {
                allowed ? DirectoryListing.read(directory, options: options) : DirectoryListing(directory: directory, nodes: nil, exists: true)
            }.value
            guard let self, self.generation == generation else { return }
            self.loading.remove(key)
            self.skeletons.remove(key)
            self.tree.apply([listing])
            self.directoryChanged([listing])
            if self.isFiltering { self.startCrawl() }
        }
    }

    /// Re-reads directories after a change (file system events, our own operations), then runs `done`.
    private func reread(_ directories: [URL], then done: @escaping @MainActor () -> Void = {}) {
        let loaded = directories.filter { tree.isLoaded($0) }
        guard !loaded.isEmpty else { done(); return }
        let generation = generation
        let options = tree.options
        Task { [weak self] in
            let listings = await Task.detached(priority: .userInitiated) { loaded.map { DirectoryListing.read($0, options: options) } }.value
            guard let self, self.generation == generation else { return }
            self.tree.apply(listings)
            self.directoryChanged(listings)
            done()
        }
    }

    /// The folder being browsed disappeared (deleted or moved in Finder): fall back to the nearest one that is left.
    private func directoryChanged(_ listings: [DirectoryListing]) {
        guard !isWorkspace, let current = location.directory,
              listings.contains(where: { !$0.exists && $0.directory.fileKey == current.fileKey }) else { return }
        var ancestor = current.deletingLastPathComponent()
        while ancestor.fileKey != "/", !FileManager.default.fileExists(atPath: ancestor.path) { ancestor.deleteLastPathComponent() }
        navigate(to: ancestor)
    }

    private func startCrawl() {
        crawl?.cancel()
        let snapshot = tree
        let generation = generation
        crawl = Task { [weak self] in
            let work = Task.detached(priority: .utility) { DirectoryCrawler.crawl(snapshot, isCancelled: { Task.isCancelled }) }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.tree.merge(found)
        }
    }

    // MARK: Watching

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        // lazy: no watching for the volume root or its direct children (every write on the disk would arrive); the folder is re-read when the window comes forward
        let roots = tree.roots.filter { $0.pathComponents.count > 2 }
        guard !roots.isEmpty else { return }
        let watcher = FolderWatcher(roots: roots, ignore: tree.options.ignore) { [weak self] directories in
            Task { @MainActor in self?.reread(Array(directories)) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    // MARK: Opening

    func isOpenable(_ url: URL) -> Bool { tree.options.markdownExtensions.contains(url.pathExtension.lowercased()) }

    /// Single click = preview tab, double click / Return = regular tab. Files that are not Markdown go to their own app.
    func open(_ url: URL, pinned: Bool) {
        guard isOpenable(url) else {
            if AppDefaults.permitsOpening(url) { NSWorkspace.shared.open(url) }
            return
        }
        do {
            try controller.open(url, as: pinned ? .pinned : .preview)
        } catch {
            log.error("open \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            present(error, title: String(localized: "Could not open “\(url.lastPathComponent)”"))
        }
    }

    // MARK: Drops

    /// Something dropped on the sidebar or the window: folders become the workspace (more roots when already in one),
    /// Markdown files open as tabs; other files are ignored (dropping a picture must not launch Preview).
    func drop(_ urls: [URL]) {
        let folders = urls.filter(OpenRouter.isFolder)
        if !folders.isEmpty { openFolders(folders) }
        for file in urls where !OpenRouter.isFolder(file) && isOpenable(file) { open(file, pinned: true) }
    }

    /// Folders dropped between favorites: new ones are added there, ones already favorites are moved there.
    func dropFavorites(_ urls: [URL], at index: Int) {
        var at = index
        for url in urls {
            if let existing = stores.favorites.firstIndex(where: { $0.url.fileKey == url.fileKey }) {
                stores.moveFavorite(stores.favorites[existing].id, to: existing < at ? at - 1 : at)
            } else {
                addFavorite(url, at: at)
            }
            at += 1
        }
    }

    // MARK: Context menu

    func perform(_ action: FileAction, on url: URL, isDirectory: Bool) {
        switch action {
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        case .newFile, .newFolder: newItem(in: FileOperations.targetDirectory(for: url, isDirectory: isDirectory), folder: action == .newFolder)
        case .rename: pendingEdit = url.fileKey
        case .moveToTrash: trash(url)
        case .addToFavorites: addFavorite(url)
        case .removeFromFavorites: stores.removeFavorite(url)
        }
    }

    func addFavorite(_ url: URL, at index: Int? = nil) {
        if stores.isFavorite(url) { return }
        if !stores.addFavorite(url, at: index) {
            let alert = NSAlert()
            alert.messageText = stores.favoritesAreFull ? String(localized: "收藏已满") : String(localized: "无法添加到收藏")
            alert.informativeText = stores.favoritesAreFull ? String(localized: "先移除一个收藏再添加。") : url.path
            present(alert)
        }
    }

    /// Makes "Untitled.md" / "Untitled Folder" in `directory` and starts renaming it in place, as Finder does.
    func newItem(in directory: URL, folder: Bool) {
        guard isAllowed(directory) else { return }
        do {
            let url = folder ? try FileOperations.createFolder(in: directory) : try FileOperations.createFile(in: directory)
            filter = ""
            if !tree.isUnderRoot(directory) { navigate(to: directory) }
            setExpanded(directory, true)
            createdFile = folder ? nil : url.fileKey
            let key = url.fileKey
            if tree.isLoaded(directory) {
                reread([directory]) { self.pendingEdit = key }
            } else {
                // Not read yet: its first read (already under way after setExpanded) will include the new item.
                Task { [weak self] in
                    for _ in 0..<100 {
                        guard let self, !self.tree.isLoaded(directory) else { break }
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    self?.pendingEdit = key
                }
            }
        } catch {
            present(error, title: String(localized: "无法新建"))
        }
    }

    /// The inline editor ended. `name` nil = cancelled (Esc): the item keeps its name.
    func finishRename(_ url: URL, name: String?) {
        let wasCreated = createdFile == url.fileKey
        if wasCreated { createdFile = nil }
        Task {
            var final = url
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != url.lastPathComponent {
                do {
                    final = try await WorkspaceRegistry.shared.rename(url, to: name)
                } catch {
                    present(error, title: String(localized: "无法重命名“\(url.lastPathComponent)”"))
                }
            }
            reread([url.deletingLastPathComponent()]) { [self] in
                pendingSelect = final.fileKey
                if wasCreated { open(final, pinned: true) }
            }
        }
    }

    /// Never a delete: `NSWorkspace.recycle` puts the item in the Trash (Finder's Put Back works). Tabs showing it close
    /// first, asking about unsaved changes; cancelling the prompt cancels the trashing.
    func trash(_ url: URL) {
        Task {
            guard await WorkspaceRegistry.shared.closeTabs(under: url) else { return }
            do { _ = try await NSWorkspace.shared.recycle([url]) } catch {
                present(error, title: String(localized: "无法移到废纸篓"))
            }
            stores.refresh()
            reread([url.deletingLastPathComponent()])
        }
    }

    // MARK: Alerts

    private func present(_ error: any Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        if let failure = error as? FileOperations.Failure {
            switch failure {
            case .invalidName: alert.informativeText = String(localized: "这个名字不能用。")
            case .exists(let name): alert.informativeText = String(localized: "“\(name)”已经存在。")
            }
        }
        present(alert)
    }

    private func present(_ alert: NSAlert) {
        if let window = window() { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
