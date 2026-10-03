import Foundation
import Testing
@testable import WorkspaceKit

struct FolderWatcherPureTests {
    private let roots = [FolderWatcher.Root(given: "/var/proj", resolved: "/private/var/proj")]

    private func affected(_ events: [(String, Bool)]) -> Set<String> {
        FolderWatcher.affectedDirectories(events.map { FolderWatcher.Event(path: $0.0, isDirectory: $0.1) }, roots: roots, ignore: .default)
    }

    @Test func aFileEventAffectsItsParentInTheCallersSpelling() {
        #expect(affected([("/private/var/proj/a/b.md", false)]) == ["/var/proj/a"])
        #expect(affected([("/private/var/proj/top.md", false)]) == ["/var/proj"])
    }

    @Test func aDirectoryEventAffectsItselfAndItsParent() {
        #expect(affected([("/private/var/proj/a/new", true)]) == ["/var/proj/a/new", "/var/proj/a"])
    }

    @Test func theRootItselfAffectsOnlyTheRoot() {
        #expect(affected([("/private/var/proj", true)]) == ["/var/proj"])
    }

    @Test func eventsInsideIgnoredDirectoriesAreDropped() {
        #expect(affected([
            ("/private/var/proj/node_modules/x/y.js", false),
            ("/private/var/proj/doc_files/fig.png", false),
            ("/private/var/proj/a/.git/index", false),
            ("/private/var/proj/.quarto/x", true),
        ]).isEmpty)
    }

    @Test func aFileNamedLikeAnIgnoredSuffixIsNotIgnored() {
        #expect(affected([("/private/var/proj/notes_files", false)]) == ["/var/proj"])
        #expect(affected([("/private/var/proj/notes_files", true)]).isEmpty)  // same name, but a directory
    }

    @Test func eventsOutsideEveryRootAreDropped() {
        #expect(affected([("/private/var/other/a.md", false), ("/private/var/projector/a.md", false)]).isEmpty)
    }
}

/// Real FSEvents on a temp directory.
struct FolderWatcherTests {
    private func makeWatcher(_ t: TempDir, ignoreSelf: Bool = false, debounce: TimeInterval = 0.2, into batches: Collector<Set<URL>>) -> FolderWatcher {
        FolderWatcher(roots: [t.url], debounce: debounce, ignoreSelf: ignoreSelf) { batches.add($0) }
    }

    private func keys(_ batches: Collector<Set<URL>>) -> Set<String> { Set(batches.all.flatMap { $0 }.map(\.fileKey)) }

    @Test func reportsTheDirectoryOfANewFileInTheCallersSpelling() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("sub")
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, into: batches)
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))  // FSEvents needs a moment before it sees changes
        try t.file("sub/a.md")
        #expect(await waitUntil { keys(batches).contains(t.url.appending(path: "sub").fileKey) })
    }

    @Test func dropsEventsInsideIgnoredDirectoriesButStillSeesTheRest() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("node_modules"); try t.dir("book_files")
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, into: batches)
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try t.file("node_modules/x.js"); try t.file("book_files/fig.png"); try t.file(".git/HEAD")
        try t.file("real/a.md")  // the sentinel: once it arrives, the ignored writes (older) would have too
        #expect(await waitUntil { keys(batches).contains(t.url.appending(path: "real").fileKey) })
        try await Task.sleep(for: .milliseconds(400))
        for key in keys(batches) {
            #expect(!key.contains("node_modules") && !key.contains("book_files") && !key.contains(".git"), "leaked \(key)")
        }
    }

    @Test func aBurstOfWritesIsCoalesced() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, debounce: 0.6, into: batches)
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        for i in 0..<30 { try t.file("burst/f\(i).md") }
        #expect(await waitUntil { !batches.all.isEmpty })
        try await Task.sleep(for: .milliseconds(900))
        #expect(batches.all.count <= 2, "got \(batches.all.count) batches for one burst")
        #expect(keys(batches).contains(t.url.appending(path: "burst").fileKey))
    }

    @Test func nothingIsDeliveredAfterStop() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, into: batches)
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(300))
        try t.file("a.md")
        #expect(await waitUntil { !batches.all.isEmpty })
        watcher.stop()
        let before = batches.all.count
        try t.file("b.md")
        try await Task.sleep(for: .milliseconds(800))
        #expect(batches.all.count == before)
    }

    @Test func ownWritesAreIgnoredWhenAsked() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, ignoreSelf: true, into: batches)
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try t.file("mine.md")
        try await Task.sleep(for: .milliseconds(900))
        #expect(batches.all.isEmpty)
    }

    @Test func aBatchAppliedToTheTreeModelRefreshesTheRightDirectory() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("sub/a.md")
        var model = FileTreeModel(roots: [t.url])
        model.setExpanded(t.url.appending(path: "sub"), true)
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, into: batches)
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try t.file("sub/b.md")
        #expect(await waitUntil { !batches.all.isEmpty })
        for batch in batches.all { model.reload(batch) }
        #expect(model.children(of: t.url.appending(path: "sub"))?.map(\.name) == ["a.md", "b.md"])
    }

    @Test func aStoppedWatcherCanBeStartedAgain() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let batches = Collector<Set<URL>>()
        let watcher = makeWatcher(t, into: batches)
        #expect(watcher.start())
        watcher.stop()
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try t.file("again.md")
        #expect(await waitUntil { !batches.all.isEmpty })
    }

    @Test func startFailsWithoutRoots() {
        #expect(!FolderWatcher(roots: [], onChange: { _ in }).start())
    }
}
