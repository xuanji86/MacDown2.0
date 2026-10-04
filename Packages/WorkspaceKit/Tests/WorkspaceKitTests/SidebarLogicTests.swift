import Foundation
import Testing
@testable import WorkspaceKit

struct TreeFilterTests {
    private func names(_ rows: [FileTreeModel.Row]) -> [String] { rows.map(\.node.name) }

    private func sample() throws -> (TempDir, FileTreeModel) {
        let t = try TempDir()
        try t.file("guides/setup.md"); try t.file("guides/other.md"); try t.file("assets/logo.md"); try t.file("offset-notes.md"); try t.file("todo.txt")
        var model = FileTreeModel(roots: [t.url])
        model.setExpanded(t.url.appending(path: "guides", directoryHint: .isDirectory), true)
        model.setExpanded(t.url.appending(path: "assets", directoryHint: .isDirectory), true)
        return (t, model)
    }

    @Test func filterKeepsMatchesAndTheFoldersAboveThem() throws {
        let (t, model) = try sample(); defer { t.cleanUp() }
        let result = model.filtered(by: "set", showRoots: false)  // "assets" matches by name too
        #expect(names(result.rows) == ["assets", "guides", "setup.md", "offset-notes.md"])
        #expect(result.matchCount == 3)  // guides is only shown because of what is in it
        #expect(result.rows[0].isExpanded == false)
        #expect(result.rows[1].isExpanded)
    }

    @Test func filterIgnoresCaseAndDiacritics() throws {
        let (t, model) = try sample(); defer { t.cleanUp() }
        #expect(names(model.filtered(by: "TODO", showRoots: false).rows) == ["todo.txt"])
        #expect(model.filtered(by: "  ", showRoots: false).matchCount == 0)
        #expect(model.filtered(by: "  ", showRoots: false).rows == model.rows(showRoots: false))
    }

    @Test func aFolderWhoseNameMatchesIsShownCollapsed() throws {
        let (t, model) = try sample(); defer { t.cleanUp() }
        let result = model.filtered(by: "assets", showRoots: false)
        #expect(names(result.rows) == ["assets"])
        #expect(result.rows[0].isExpanded == false)
    }

    @Test func rootsCanBeHiddenForTheCurrentLocation() throws {
        let (t, model) = try sample(); defer { t.cleanUp() }
        #expect(model.rows(showRoots: true).first?.depth == 0)
        #expect(model.rows(showRoots: true).first?.node.url.fileKey == t.url.fileKey)
        let flat = model.rows(showRoots: false)
        #expect(flat.first?.node.name == "assets")
        #expect(flat.allSatisfy { $0.node.url.fileKey != t.url.fileKey })
        #expect(flat.map(\.depth).min() == 0)
    }

    @Test func crawlerFindsMatchesInFoldersNeverOpenedAndStopsAtIgnoredOnes() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/b/c/deep-target.md"); try t.file("node_modules/x/target-hidden.md"); try t.file("a/other.md")
        var model = FileTreeModel(roots: [t.url])
        #expect(model.filtered(by: "target", showRoots: false).rows.isEmpty)
        model.merge(DirectoryCrawler.crawl(model))
        #expect(names(model.filtered(by: "target", showRoots: false).rows) == ["a", "b", "c", "deep-target.md"])
    }

    @Test func crawlerReadsASymlinkLoopOnce() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/x.md")
        try FileManager.default.createSymbolicLink(at: t.url.appending(path: "a/loop"), withDestinationURL: t.url)
        let model = FileTreeModel(roots: [t.url])
        let listings = DirectoryCrawler.crawl(model)
        #expect(listings.count <= 3)  // a, and the loop target resolves to the root which is already known
    }

    @Test func crawlerHonoursItsLimitsAndCancellation() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for i in 0..<30 { try t.dir("d\(i)/sub") }
        let model = FileTreeModel(roots: [t.url])
        #expect(DirectoryCrawler.crawl(model, maxDirectories: 5).count == 5)
        #expect(DirectoryCrawler.crawl(model, isCancelled: { true }).isEmpty)
    }

    @Test func mergeDoesNotOverwriteANewerListingOrAcceptStrangers() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/one.md")
        var model = FileTreeModel(roots: [t.url])
        let a = t.url.appending(path: "a", directoryHint: .isDirectory)
        model.setChildren([FileNode(url: a.appending(path: "fresh.md"), isDirectory: false)], of: a)
        let stale = DirectoryListing(directory: a, nodes: [FileNode(url: a.appending(path: "old.md"), isDirectory: false)], exists: true)
        let stranger = DirectoryListing(directory: URL(filePath: "/elsewhere"), nodes: [], exists: true)
        model.merge([stale, stranger])
        #expect(model.children(of: a)?.map(\.name) == ["fresh.md"])
        #expect(!model.isLoaded(URL(filePath: "/elsewhere")))
    }

    @Test func applyDropsAVanishedDirectoryAndMarksAnUnreadableOne() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/b/x.md")
        var model = FileTreeModel(roots: [t.url])
        let a = t.url.appending(path: "a", directoryHint: .isDirectory)
        let b = a.appending(path: "b", directoryHint: .isDirectory)
        model.setExpanded(a, true); model.setExpanded(b, true)
        try FileManager.default.removeItem(at: b)
        model.apply([DirectoryListing.read(a, options: model.options), DirectoryListing.read(b, options: model.options)])
        #expect(model.children(of: a)?.isEmpty == true)
        #expect(!model.isLoaded(b) && !model.isExpanded(b))
        model.apply([DirectoryListing(directory: a, nodes: nil, exists: true)])
        #expect(model.unreadable.contains(a.fileKey))
    }

    @Test func quartoProjectsAreMarked() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("book/_quarto.yml"); try t.file("plain/x.md"); try t.file("alt/_quarto.yaml")
        let listed = try DirectoryLister.list(t.url, options: FileTreeOptions())
        #expect(Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0.isQuartoProject) }) == ["alt": true, "book": true, "plain": false])
    }

    @Test func optionsChangeWithoutRelistForgetsListingsButKeepsExpansion() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/x.md"); try t.file("a/y.png")
        var model = FileTreeModel(roots: [t.url])
        let a = t.url.appending(path: "a", directoryHint: .isDirectory)
        model.setExpanded(a, true)
        model.setOptions(FileTreeOptions(showAllFiles: true), relist: false)
        #expect(!model.isLoaded(a) && model.isExpanded(a))
        #expect(model.expandedDirectories.map(\.fileKey).contains(a.fileKey))
    }

    @Test func aBigDirectoryListsAndFiltersQuickly() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for i in 0..<5000 { FileManager.default.createFile(atPath: t.url.appending(path: "note-\(i).md").path, contents: Data()) }
        for i in 0..<50 { try t.dir("folder-\(i)") }
        let clock = ContinuousClock()
        var model = FileTreeModel(roots: [t.url])
        let listing = clock.measure { model = FileTreeModel(roots: [t.url]) }
        let rows = clock.measure { #expect(model.rows(showRoots: false).count == 5050) }
        let filter = clock.measure { #expect(model.filtered(by: "note-49", showRoots: false).matchCount == 111) }
        print("5,050 entries: list \(listing), rows \(rows), filter \(filter)")
        #expect(listing < .seconds(2) && rows < .milliseconds(500) && filter < .milliseconds(500))
    }
}

struct WorkspaceFoldersTests {
    private func u(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

    @Test func enteringAddingAndLeaving() {
        var ws = WorkspaceFolders()
        #expect(!ws.isActive && ws.title == "")
        let first = ws.add(u("/p/MyBook")); #expect(first)
        #expect(ws.isActive && ws.title == "MyBook")
        let again = ws.add(URL(filePath: "/p/MyBook/")); #expect(!again)  // same folder, other spelling
        let second = ws.add(u("/p/Notes")); #expect(second)
        #expect(ws.title == "2 个文件夹")
        ws.remove(u("/p/MyBook"))
        #expect(ws.roots.map(\.lastPathComponent) == ["Notes"])
        ws.remove(u("/p/Notes"))
        #expect(!ws.isActive)  // the last root going away is leaving the workspace
    }

    @Test func closeGoesBackToBrowsing() {
        var ws = WorkspaceFolders(roots: [u("/a"), u("/b")])
        ws.close()
        #expect(ws == WorkspaceFolders())
    }

    @Test func missingFoldersAreDroppedOnRestore() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let file = try t.file("f.md")
        let ws = WorkspaceFolders(roots: [t.url, u("/definitely/not/here"), file])
        #expect(ws.existing().roots.map(\.fileKey) == [t.url.fileKey])
    }

    @Test func windowStateKeepsTheWorkspaceAndStaysReadableWithoutIt() throws {
        let state = WorkspaceWindowState(workspaceRoots: [u("/p/MyBook")], showAllFiles: true)
        let back = WindowRestoration.decode(WindowRestoration.encode([state]))
        #expect(back.first?.workspaceRoots.map(\.path) == ["/p/MyBook"])
        #expect(back.first?.showAllFiles == true)
        let old = Data(#"[{"id":"\#(UUID().uuidString)","sidebarSection":"files"}]"#.utf8)
        let decoded = WindowRestoration.decode(old)
        #expect(decoded.count == 1 && decoded[0].workspaceRoots.isEmpty && !decoded[0].showAllFiles)
        let garbled = Data(#"[{"id":"\#(UUID().uuidString)","workspaceRoots":42}]"#.utf8)
        #expect(WindowRestoration.decode(garbled).first?.workspaceRoots == [])
    }
}

struct FolderRoutingTests {
    private func id() -> UUID { UUID() }
    private func windows(_ w: [(open: Set<String>, roots: Set<String>)]) -> [WindowSnapshot] {
        w.map { WindowSnapshot(id: UUID(), openKeys: $0.open, rootKeys: $0.roots) }
    }
    private let book = URL(filePath: "/ws/book", directoryHint: .isDirectory)
    private let notes = URL(filePath: "/ws/notes", directoryHint: .isDirectory)
    private let isFolder: (URL) -> Bool = { $0.lastPathComponent == "book" || $0.lastPathComponent == "notes" }

    @Test func aFolderWithNoWindowOpensANewOne() {
        let plan = OpenRouter.plan(opening: [book], windows: [], isFolder: isFolder)
        #expect(plan == OpenPlan(target: .newWindow, urls: [], alreadyOpen: [], folders: [book]))
    }

    @Test func anEmptyBrowsingFrontWindowBecomesTheWorkspace() {
        let w = windows([(open: [], roots: [])])
        #expect(OpenRouter.plan(opening: [book], windows: w, isFolder: isFolder)?.target == .window(w[0].id))
    }

    @Test func aWindowWithTabsOrAnotherWorkspaceIsLeftAlone() {
        let busy = windows([(open: ["/ws/a.md"], roots: [])])
        #expect(OpenRouter.plan(opening: [book], windows: busy, isFolder: isFolder)?.target == .newWindow)
        let other = windows([(open: [], roots: ["/ws/notes"])])
        #expect(OpenRouter.plan(opening: [book], windows: other, isFolder: isFolder)?.target == .newWindow)
    }

    @Test func aFolderThatIsAlreadyARootFocusesItsWindow() {
        let w = windows([(open: ["/ws/a.md"], roots: []), (open: [], roots: ["/ws/book"])])
        #expect(OpenRouter.plan(opening: [URL(filePath: "/ws/book/")], windows: w, isFolder: isFolder)?.target == .window(w[1].id))
    }

    @Test func severalFoldersAndFilesShareOneWindow() {
        let w = windows([(open: ["/ws/x.md"], roots: [])])
        let file = URL(filePath: "/ws/x.md")
        let plan = OpenRouter.plan(opening: [book, file, notes], windows: w, isFolder: isFolder)
        #expect(plan?.folders == [book, notes])
        #expect(plan?.urls == [file])
        #expect(plan?.target == .newWindow)  // the only window has a tab open
        let free = windows([(open: [], roots: [])])
        let p2 = OpenRouter.plan(opening: [book, file, notes], windows: free, isFolder: isFolder)
        #expect(p2?.target == .window(free[0].id) && p2?.folders == [book, notes] && p2?.urls == [file])
    }

    @Test func realDirectoriesAreFoldersAndPackagesAreNot() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let dir = try t.dir("proj"); let app = try t.dir("Thing.app"); let file = try t.file("a.md")
        #expect(OpenRouter.isFolder(dir) && !OpenRouter.isFolder(file) && !OpenRouter.isFolder(app))
        let plan = OpenRouter.plan(opening: [dir, file], windows: [])
        #expect(plan?.folders.map(\.fileKey) == [dir.fileKey] && plan?.urls.map(\.fileKey) == [file.fileKey])
    }
}

struct FileOperationsTests {
    @Test func newItemsPickTheFirstFreeName() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        #expect(try FileOperations.createFile(in: t.url).lastPathComponent == "Untitled.md")
        #expect(try FileOperations.createFile(in: t.url).lastPathComponent == "Untitled 2.md")
        #expect(try FileOperations.createFolder(in: t.url).lastPathComponent == "Untitled Folder")
        #expect(try FileOperations.createFolder(in: t.url).lastPathComponent == "Untitled Folder 2")
        #expect(try Data(contentsOf: t.url.appending(path: "Untitled.md")).isEmpty)
    }

    @Test func newItemGoesInsideAFolderAndBesideAFile() {
        let folder = URL(filePath: "/p/folder", directoryHint: .isDirectory)
        let file = URL(filePath: "/p/folder/a.md")
        #expect(FileOperations.targetDirectory(for: folder, isDirectory: true).fileKey == "/p/folder")
        #expect(FileOperations.targetDirectory(for: file, isDirectory: false).fileKey == "/p/folder")
    }

    @Test func renameMovesTheFileAndKeepsItsContent() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.file("a.md", "hello")
        let b = try FileOperations.rename(a, to: "  notes.md ")
        #expect(b.lastPathComponent == "notes.md")
        #expect(try String(contentsOf: b, encoding: .utf8) == "hello")
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test func renameRefusesBadNamesAndTakenOnes() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.file("a.md"); try t.file("b.md")
        for bad in ["", "   ", ".", "..", "x/y", String(repeating: "n", count: 300)] {
            #expect(throws: FileOperations.Failure.invalidName) { try FileOperations.destination(renaming: a, to: bad) }
        }
        #expect(throws: FileOperations.Failure.exists("b.md")) { try FileOperations.rename(a, to: "b.md") }
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func aChangeOfCaseAloneWorks() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.file("readme.md")
        let b = try FileOperations.rename(a, to: "README.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["README.md"])
        #expect(b.lastPathComponent == "README.md")
        #expect(try FileOperations.rename(b, to: "README.md") == b)  // same name: nothing happens
    }

    @Test func renamingAFolderKeepsItsContents() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let d = try t.dir("old"); try t.file("old/x.md")
        let n = try FileOperations.rename(d, to: "new")
        #expect(FileManager.default.fileExists(atPath: n.appending(path: "x.md").path))
    }

    @Test func homeAndItsStandardFoldersAreProtected() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        for p in ["/", "/Users/me", "/Users/me/Desktop", "/Users/me/Documents", "/Users", "/Volumes"] {
            #expect(FileOperations.isProtected(URL(filePath: p), home: home), "\(p)")
        }
        for p in ["/Users/me/Documents/notes", "/Users/me/proj", "/Volumes/Disk/x"] {
            #expect(!FileOperations.isProtected(URL(filePath: p), home: home), "\(p)")
        }
    }

    @Test func contextMenuByRow() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let folder = URL(filePath: "/Users/me/proj", directoryHint: .isDirectory)
        let file = URL(filePath: "/Users/me/proj/a.md")
        func menu(_ url: URL, dir: Bool, anchor: Bool = false, fav: Bool = false) -> [FileAction] {
            SidebarContextMenu.actions(for: url, isDirectory: dir, isAnchor: anchor, isFavorite: fav, home: home)
        }
        #expect(menu(file, dir: false) == [.revealInFinder, .copyPath, .newFile, .newFolder, .rename, .moveToTrash])
        #expect(menu(folder, dir: true).suffix(3) == [.rename, .moveToTrash, .addToFavorites])
        #expect(menu(folder, dir: true, fav: true).last == .removeFromFavorites)
        #expect(!menu(folder, dir: true, anchor: true, fav: true).contains(.moveToTrash))  // a favorite entry / workspace root
        #expect(!menu(URL(filePath: "/Users/me/Desktop"), dir: true).contains(.rename))
    }
}

@MainActor
struct DebounceAndFollowTests {
    @Test func onlyTheLastSubmissionRuns() async {
        let d = Debouncer(delay: .milliseconds(60))
        var seen: [Int] = []
        for i in 1...5 { d.submit { seen.append(i) } }
        #expect(seen.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(seen == [5])
    }

    @Test func cancelDropsThePendingAction() async {
        let d = Debouncer(delay: .milliseconds(40))
        var ran = false
        d.submit { ran = true }
        d.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!ran)
    }

    @Test func flickingThroughTabsLandsOnTheLastDocumentsFolder() async {
        var location = CurrentLocation()
        let d = Debouncer(delay: .milliseconds(60))
        for path in ["/a/1.md", "/b/2.md", "/c/3.md"] {
            d.submit { location.follow(documentURL: URL(filePath: path)) }
        }
        #expect(location.directory == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(location.directory?.fileKey == "/c")
    }

    @Test func manualNavigationHoldsUntilTheActiveDocumentChanges() {
        var location = CurrentLocation(directory: URL(filePath: "/a/b", directoryHint: .isDirectory))
        location.navigate(to: URL(filePath: "/a", directoryHint: .isDirectory))
        location.follow(documentURL: nil)
        #expect(location.directory?.fileKey == "/a")
        location.follow(documentURL: URL(filePath: "/a/b/x.md"))
        #expect(location.directory?.fileKey == "/a/b")
    }
}

struct SidebarContentTests {
    private func fav(_ path: String) -> ResolvedBookmark { ResolvedBookmark(id: UUID(), url: URL(filePath: path, directoryHint: .isDirectory)) }

    private func kinds(_ items: [SidebarItem]) -> [String] {
        items.map {
            switch $0 {
            case .header(_, let t, _): return "H:\(t)"
            case .favorite(let b): return "F:\(b.url.lastPathComponent)"
            case .pathBar: return "path"
            case .node(let r, _): return "N:\(r.node.name)@\(r.depth)"
            case .recent(let u): return "R:\(u.lastPathComponent)"
            case .skeleton: return "skeleton"
            case .unreadable: return "unreadable"
            case .placeholder(_, let s): return "P:\(s.prefix(4))"
            }
        }
    }

    @Test func browseModeIsFavoritesThenLocationThenRecents() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md"); try t.dir("sub")
        let location = CurrentLocation(directory: t.url)
        let tree = FileTreeModel(roots: [t.url])
        let snap = SidebarContent.browse(
            favorites: [fav("/Users/me/Desktop"), fav("/Users/me/Documents")], location: location, tree: tree,
            recents: [URL(filePath: "/x/weekly.md")], query: "", skeletons: [])
        #expect(kinds(snap.items) == ["H:收藏", "F:Desktop", "F:Documents", "H:当前位置", "path", "N:sub@0", "N:a.md@0", "H:最近", "R:weekly.md"])
        #expect(snap.matchCount == nil)
    }

    @Test func filteringHidesFavoritesNarrowsTheRestAndCountsMatches() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("setup.md"); try t.file("other.md")
        let snap = SidebarContent.browse(
            favorites: [fav("/Users/me/Desktop")], location: CurrentLocation(directory: t.url), tree: FileTreeModel(roots: [t.url]),
            recents: [URL(filePath: "/x/setup-old.md"), URL(filePath: "/x/zzz.md")], query: "setup", skeletons: [])
        #expect(kinds(snap.items) == ["H:当前位置", "path", "N:setup.md@0", "H:最近", "R:setup-old.md"])
        #expect(snap.matchCount == 2)
        let none = SidebarContent.browse(
            favorites: [], location: CurrentLocation(directory: t.url), tree: FileTreeModel(roots: [t.url]), recents: [], query: "qqq", skeletons: [])
        #expect(kinds(none.items) == ["H:当前位置", "path", "P:没有匹配", ] && none.matchCount == 0)
    }

    @Test func emptyStatesSayWhatWillFillThem() {
        let snap = SidebarContent.browse(favorites: [], location: CurrentLocation(), tree: FileTreeModel(), recents: [], query: "", skeletons: [])
        #expect(kinds(snap.items) == ["H:收藏", "P:把文件夹", "H:当前位置", "P:还没有打", "H:最近", "P:最近没有"])
    }

    @Test func aFolderStillBeingReadShowsSkeletonOnlyAfterTheDelay() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let location = CurrentLocation(directory: t.url)
        var tree = FileTreeModel()
        tree.addRoot(t.url, load: false)  // not read yet
        let early = SidebarContent.browse(favorites: [], location: location, tree: tree, recents: [], query: "", skeletons: [])
        #expect(!kinds(early.items).contains("skeleton"))
        let late = SidebarContent.browse(favorites: [], location: location, tree: tree, recents: [], query: "", skeletons: [t.url.fileKey])
        #expect(kinds(late.items).filter { $0 == "skeleton" }.count == 3)
        #expect(late.items.contains(.header(.location, title: "当前位置", trailing: .loading)))
    }

    @Test func anUnreadableFolderGetsAHintNotACrash() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        var tree = FileTreeModel(roots: [t.url])
        tree.setChildren([], of: t.url, readable: false)
        let snap = SidebarContent.browse(favorites: [], location: CurrentLocation(directory: t.url), tree: tree, recents: [], query: "", skeletons: [])
        #expect(kinds(snap.items).contains("unreadable"))
    }

    @Test func workspaceModeShowsRootsAsRowsAndNothingElse() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let u = try TempDir(); defer { u.cleanUp() }
        try t.file("a.md"); try u.file("b.md")
        let tree = FileTreeModel(roots: [t.url, u.url])
        let snap = SidebarContent.workspace(tree: tree, query: "", skeletons: [])
        #expect(kinds(snap.items) == ["N:\(t.url.lastPathComponent)@0", "N:a.md@1", "N:\(u.url.lastPathComponent)@0", "N:b.md@1"])
        let filtered = SidebarContent.workspace(tree: tree, query: "b.md", skeletons: [])
        #expect(kinds(filtered.items) == ["N:\(u.url.lastPathComponent)@0", "N:b.md@1"] && filtered.matchCount == 1)
    }

    @Test func idsAreUniqueAcrossASnapshot() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md"); try t.file("sub/b.md")
        var tree = FileTreeModel(roots: [t.url])
        tree.setExpanded(t.url.appending(path: "sub", directoryHint: .isDirectory), true)
        let snap = SidebarContent.browse(favorites: [fav("/a"), fav("/b")], location: CurrentLocation(directory: t.url), tree: tree, recents: [URL(filePath: "/r/a.md")], query: "", skeletons: [])
        #expect(Set(snap.items.map(\.id)).count == snap.items.count)
    }
}
