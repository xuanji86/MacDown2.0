import CoreServices
import Foundation
import Testing
@testable import WorkspaceKit

/// Regression tests for the workspace / file-tree review (rename, create, protection, watcher, reads, recents, Quarto probe).

struct RenameSafetyTests {
    @Test func aCaseOnlyDestinationThatIsADistinctEntryIsACollision() throws {
        // On a case-sensitive volume `notes.md` and `NOTES.md` are two files. The default volume is case-insensitive, so the
        // identity check is injected: "the other name is a different directory entry".
        let t = try TempDir(); defer { t.cleanUp() }
        let notes = try t.file("notes.md")
        #expect(throws: FileOperations.Failure.exists("NOTES.md")) {
            try FileOperations.destination(renaming: notes, to: "NOTES.md", isSameEntry: { _, _ in false })
        }
    }

    @Test func aCaseOnlyDestinationThatIsTheSameEntryIsAccepted() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let notes = try t.file("notes.md")
        // Same entry: either the volume is case-insensitive (the real check says yes) or the identity says so.
        let target = try FileOperations.destination(renaming: notes, to: "NOTES.md", isSameEntry: { _, _ in true })
        #expect(target.lastPathComponent == "NOTES.md")
    }

    @Test func differentNamesAreNeverCaseOnly() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.file("a.md"); try t.file("b.md")
        #expect(throws: FileOperations.Failure.exists("b.md")) {
            try FileOperations.destination(renaming: a, to: "b.md", isSameEntry: { _, _ in true })  // identity does not excuse it
        }
    }

    @Test func realIdentityRecognisesTheSameEntryOnly() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.file("a.md"), b = try t.file("b.md")
        #expect(FileOperations.isSameEntry(a, a))
        #expect(!FileOperations.isSameEntry(a, b))
        #expect(!FileOperations.isSameEntry(a, t.url.appending(path: "missing.md")))
    }

    @Test func protectedFoldersCannotBeRenamedEvenThroughASymlink() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let home = try t.dir("home"); try t.dir("home/Documents"); try t.dir("home/proj")
        let ws = try t.dir("ws")
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "home-link"), withDestinationURL: home)
        let viaLink = ws.appending(path: "home-link/Documents", directoryHint: .isDirectory)
        #expect(FileOperations.isProtected(viaLink, home: home))
        #expect(FileOperations.isProtected(ws.appending(path: "home-link", directoryHint: .isDirectory), home: home))
        #expect(throws: FileOperations.Failure.protected("Documents")) { try FileOperations.rename(viaLink, to: "Docs", home: home) }
        #expect(throws: FileOperations.Failure.protected("Documents")) { try FileOperations.requireUnprotected(viaLink, home: home) }
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "Documents").path))
        // an ordinary folder under the same link is fine
        let proj = ws.appending(path: "home-link/proj", directoryHint: .isDirectory)
        #expect(!FileOperations.isProtected(proj, home: home))
        #expect(try FileOperations.rename(proj, to: "proj2", home: home).lastPathComponent == "proj2")
    }
}

struct ExclusiveCreateTests {
    @Test func concurrentCreatesNeverShareOrOverwriteAName() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let made = Collector<String>()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if let url = try? FileOperations.createFile(in: t.url) {
                try? Data("file \(i)".utf8).write(to: url)
                made.add(url.lastPathComponent)
            }
        }
        #expect(made.all.count == 40 && Set(made.all).count == 40)
        let contents = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(contents.count == 40)
    }

    @Test func anExistingFileIsNeverReplaced() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let first = try t.file("Untitled.md", "precious")
        let made = try FileOperations.createFile(in: t.url)
        #expect(made.lastPathComponent == "Untitled 2.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "precious")
        try t.dir("Untitled Folder")
        #expect(try FileOperations.createFolder(in: t.url).lastPathComponent == "Untitled Folder 2")
    }
}

struct WatcherEventTests {
    private let roots = [FolderWatcher.Root(given: "/var/proj", resolved: "/private/var/proj")]
    private func analyze(_ events: [FolderWatcher.Event]) -> FolderWatcher.Analysis {
        FolderWatcher.analyze(events, roots: roots, ignore: .default)
    }

    @Test func aMustScanEventNamesTheSubtreeAndItsParent() {
        let a = analyze([FolderWatcher.Event(path: "/private/var/proj/a/b", isDirectory: true, mustRescan: true)])
        #expect(a.subtrees == ["/var/proj/a/b"])
        #expect(a.directories == ["/var/proj/a/b", "/var/proj/a"])
        #expect(!a.rootChanged)
    }

    @Test func flagsFromFSEventsAreKept() {
        let ids: [(Int, Bool, Bool)] = [
            (kFSEventStreamEventFlagMustScanSubDirs, true, false), (kFSEventStreamEventFlagUserDropped, true, false),
            (kFSEventStreamEventFlagKernelDropped, true, false), (kFSEventStreamEventFlagRootChanged, false, true),
            (kFSEventStreamEventFlagItemIsDir, false, false),
        ]
        for (flag, rescan, root) in ids {
            let e = FolderWatcher.Event.make(path: "/x", flags: FSEventStreamEventFlags(flag))
            #expect(e.mustRescan == rescan && e.rootChanged == root, "flag \(flag)")
        }
    }

    @Test func aMustScanEventInsideAnIgnoredDirectoryIsStillIgnored() {
        #expect(analyze([FolderWatcher.Event(path: "/private/var/proj/node_modules/x", isDirectory: true, mustRescan: true)]).directories.isEmpty)
    }

    @Test func aRootChangedEventNamesTheRootInTheCallersSpelling() {
        let a = analyze([FolderWatcher.Event(path: "/private/var/proj", isDirectory: true, rootChanged: true)])
        #expect(a.rootChanged && a.subtrees == ["/var/proj"] && a.directories == ["/var/proj"])
        // an ancestor that moved affects the roots below it
        let b = analyze([FolderWatcher.Event(path: "/private/var", isDirectory: true, rootChanged: true)])
        #expect(b.rootChanged && b.subtrees == ["/var/proj"])
        // an unrelated path does not
        #expect(!analyze([FolderWatcher.Event(path: "/private/var/other", isDirectory: true, rootChanged: true)]).rootChanged)
    }
}

struct WatcherRootChangeTests {
    @Test func renamingAnAncestorOfTheRootIsReported() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let project = try t.dir("parent/project")
        let batches = Collector<FolderWatcher.Batch>()
        let watcher = FolderWatcher(roots: [project], debounce: 0.2, ignoreSelf: false, watchRoot: true) { batches.add($0) }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.moveItem(at: t.url.appending(path: "parent"), to: t.url.appending(path: "parent-renamed"))
        #expect(await waitUntil { batches.all.contains { $0.rootChanged } })
        let batch = try #require(batches.all.first { $0.rootChanged })
        #expect(batch.subtrees.map(\.fileKey).contains(project.fileKey))
    }

    @Test func withoutWatchRootNothingIsReportedForAnAncestorMove() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let project = try t.dir("parent/project")
        let batches = Collector<FolderWatcher.Batch>()
        let watcher = FolderWatcher(roots: [project], debounce: 0.2, ignoreSelf: false, watchRoot: false) { batches.add($0) }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.moveItem(at: t.url.appending(path: "parent"), to: t.url.appending(path: "parent-renamed"))
        try await Task.sleep(for: .milliseconds(800))
        #expect(!batches.all.contains { $0.rootChanged })
    }
}

struct TreeRefreshTests {
    @Test func loadedDirectoriesUnderASubtree() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/b/x.md"); try t.file("a/c/y.md"); try t.file("z/w.md")
        var model = FileTreeModel(roots: [t.url])
        for d in ["a", "a/b", "a/c", "z"] { model.setExpanded(t.url.appending(path: d, directoryHint: .isDirectory), true) }
        let under = model.loadedDirectories(under: t.url.appending(path: "a", directoryHint: .isDirectory)).map(\.lastPathComponent)
        #expect(under == ["a", "b", "c"])
        #expect(model.loadedDirectories(under: t.url.appending(path: "ab", directoryHint: .isDirectory)).isEmpty)  // a prefix of the name is not a subtree
        #expect(model.loadedDirectories.count == 5)
    }

    @Test func aSubtreeRescanRefreshesStaleDescendants() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/b/x.md")
        var model = FileTreeModel(roots: [t.url])
        let a = t.url.appending(path: "a", directoryHint: .isDirectory), b = a.appending(path: "b", directoryHint: .isDirectory)
        model.setExpanded(a, true); model.setExpanded(b, true)
        try t.file("a/b/new.md")  // an event that FSEvents dropped
        let stale = model.children(of: b)?.map(\.name)
        #expect(stale == ["x.md"])
        let listings = model.loadedDirectories(under: a).map { DirectoryListing.read($0, options: model.options) }
        #expect(model.wouldChange(by: listings))
        model.apply(listings)
        #expect(model.children(of: b)?.map(\.name) == ["new.md", "x.md"])
        #expect(!model.wouldChange(by: listings))  // nothing new the second time: no redraw
    }

    @Test func disabledQuartoDetectionNeverProbes() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("book/_quarto.yml"); try t.file("plain/x.md")
        let probes = Collector<String>()
        let probe: (URL) -> Bool = { probes.add($0.lastPathComponent); return DirectoryLister.isQuartoProject($0) }
        let off = try DirectoryLister.list(t.url, options: FileTreeOptions(detectsQuartoProjects: false), quartoProbe: probe)
        #expect(probes.all.isEmpty)
        #expect(off.allSatisfy { !$0.isQuartoProject })
        let on = try DirectoryLister.list(t.url, options: FileTreeOptions(detectsQuartoProjects: true), quartoProbe: probe)
        #expect(Set(probes.all) == ["book", "plain"])
        #expect(on.first { $0.name == "book" }?.isQuartoProject == true)
    }

    @Test func aQuartoRootIsNotMarkedWhileDetectionIsOff() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("_quarto.yml")
        let off = FileTreeModel(roots: [t.url], options: FileTreeOptions(detectsQuartoProjects: false))
        #expect(off.rows().first?.node.isQuartoProject == false)
        let on = FileTreeModel(roots: [t.url], options: FileTreeOptions(detectsQuartoProjects: true))
        #expect(on.rows().first?.node.isQuartoProject == true)
    }
}

struct ReadTrackerTests {
    @Test func aChangeDuringARunningReadQueuesExactlyOneFollowUp() {
        var t = ReadTracker<Int>()
        let starts = t.request("/a")
        let dirty1 = t.request("/a", then: 1), dirty2 = t.request("/a", then: 2)
        #expect(starts)  // the first read starts
        #expect(!dirty1 && !dirty2)  // changes while it runs: marked dirty, no second concurrent read
        let first = t.finish("/a")
        #expect(first.done.isEmpty && first.again)  // the follow-up starts; the first read owed nothing to those requests
        #expect(t.isReading("/a"))
        let second = t.finish("/a")
        #expect(second.done == [1, 2] && !second.again)  // callbacks wait for a read that began after the change
        #expect(!t.isReading("/a"))
    }

    @Test func aQuietReadFinishesWithItsOwnCallbacks() {
        var t = ReadTracker<Int>()
        let a = t.request("/a", then: 7), b = t.request("/b")  // directories are independent
        #expect(a && b)
        let r = t.finish("/a")
        #expect(r.done == [7] && !r.again)
        #expect(t.isReading("/b"))
        let again = t.request("/a")  // idle again: the next request starts a read
        #expect(again)
    }

    @Test func resetForgetsEverythingInFlight() {
        var t = ReadTracker<Int>()
        _ = t.request("/a"); _ = t.request("/a", then: 1)
        t.reset()
        #expect(!t.isReading("/a"))
        let r = t.finish("/a")
        #expect(r.done.isEmpty)
    }
}

struct RecentsRenameOrderTests {
    @Test func renamingAnOpenFileDoesNotDuplicateItsRecentEntry() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let suite = "WorkspaceKitTests." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = RecentsStore(defaults: UserDefaults(suiteName: suite)!)
        let old = try t.file("old.md")
        store.noteOpened(old)
        let idOfOld = store.refresh()[0].id
        let new = t.url.appending(path: "new.md")
        try FileManager.default.moveItem(at: old, to: new)
        store.noteOpened(new)  // the app's order: the new path is noted before anything refreshed the list
        #expect(store.count == 1)
        let list = store.refresh()
        #expect(list.map(\.url.lastPathComponent) == ["new.md"])
        #expect(list[0].id == idOfOld)
    }

    @Test func entriesThatAlreadyResolveToTheSameFileCollapse() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let suite = "WorkspaceKitTests." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = RecentsStore(defaults: defaults)
        let a = try t.file("a.md")
        store.noteOpened(a)
        // a duplicate left behind by the old order of events: a second entry for the same file under another path
        var duplicate = try #require(store.entry(for: a))
        duplicate.path = "/stale/path"
        store.entries.append(duplicate)
        #expect(store.count == 2)
        #expect(store.refresh().count == 1)
        #expect(store.count == 1)
    }
}

struct FolderRenameValidationTests {
    /// `WorkspaceRegistry.rename` asks for the destination of a folder rename before it closes any tab, so a taken or invalid
    /// name must already be refused by `destination`, with nothing renamed.
    @Test func aFolderRenameToATakenOrInvalidNameIsRefusedUpFront() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let a = try t.dir("a"), b = try t.dir("b")
        #expect(throws: FileOperations.Failure.exists("b")) { try FileOperations.destination(renaming: a, to: "b") }
        #expect(throws: FileOperations.Failure.invalidName) { try FileOperations.destination(renaming: a, to: "x/y") }
        #expect(try FileOperations.destination(renaming: a, to: "a").path == a.path)  // unchanged name: nothing to do
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }
}
