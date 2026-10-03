import Foundation
import Testing
@testable import WorkspaceKit

/// A throwaway UserDefaults domain.
private struct Defaults {
    let suite = "WorkspaceKitTests." + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    func cleanUp() { UserDefaults().removePersistentDomain(forName: suite) }
}

struct FavoritesStoreTests {
    @Test func seedsOnceAndRemovedDefaultsStayRemoved() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let desktop = try t.dir("Desktop"), docs = try t.dir("Documents")
        let store = FavoritesStore(defaults: d.defaults, seed: [desktop, docs])
        #expect(store.refresh().map(\.url.lastPathComponent) == ["Desktop", "Documents"])
        store.remove(id: store.refresh()[0].id)

        let again = FavoritesStore(defaults: d.defaults, seed: [desktop, docs])  // "next launch"
        #expect(again.refresh().map(\.url.lastPathComponent) == ["Documents"])
    }

    @Test func standardLocationsOnlyListWhatExists() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("Desktop")
        #expect(FavoritesStore.standardLocations(home: t.url).map(\.lastPathComponent) == ["Desktop"])
    }

    @Test func addDedupesAndRefusesMissingFoldersAndAFullList() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let a = try t.dir("a"), b = try t.dir("b"), c = try t.dir("c")
        let store = FavoritesStore(defaults: d.defaults, capacity: 2, seed: [])
        #expect(store.add(a))
        #expect(!store.add(a))
        #expect(!store.add(t.url.appending(path: "nope")))
        #expect(store.add(b))
        #expect(!store.add(c))  // full: refuses instead of dropping the user's favorite
        #expect(store.refresh().map(\.url.lastPathComponent) == ["a", "b"])
    }

    @Test func moveReorders() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let store = FavoritesStore(defaults: d.defaults, seed: [try t.dir("a"), try t.dir("b"), try t.dir("c")])
        store.move(id: store.refresh()[2].id, toIndex: 0)
        #expect(store.refresh().map(\.url.lastPathComponent) == ["c", "a", "b"])
        #expect(FavoritesStore(defaults: d.defaults, seed: []).refresh().map(\.url.lastPathComponent) == ["c", "a", "b"])
    }

    @Test func aMovedFolderIsFoundAgain() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let old = try t.dir("old")
        let store = FavoritesStore(defaults: d.defaults, seed: [old])
        let id = store.refresh()[0].id
        try FileManager.default.moveItem(at: old, to: t.url.appending(path: "renamed", directoryHint: .isDirectory))
        let found = store.refresh()
        #expect(found.map(\.id) == [id])
        #expect(found[0].url.lastPathComponent == "renamed")
        // the refreshed location is what got persisted
        #expect(FavoritesStore(defaults: d.defaults, seed: []).refresh().map(\.url.lastPathComponent) == ["renamed"])
    }

    @Test func aDeletedFolderIsPrunedAndStaysGone() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let a = try t.dir("a"), b = try t.dir("b")
        let store = FavoritesStore(defaults: d.defaults, seed: [a, b])
        try FileManager.default.removeItem(at: a)
        #expect(store.refresh().map(\.url.lastPathComponent) == ["b"])
        #expect(store.count == 1)
    }

    @Test func trashAndUnmountedVolumeRules() {
        #expect(BookmarkStore.isInTrash(URL(filePath: "/Users/x/.Trash/a.md")))
        #expect(!BookmarkStore.isInTrash(URL(filePath: "/Users/x/Documents/a.md")))
        #expect(BookmarkStore.isOnUnmountedVolume("/Volumes/NoSuchVolume-\(UUID().uuidString)/proj"))
        #expect(!BookmarkStore.isOnUnmountedVolume("/Users/x/proj"))
    }

    @Test func anEntryOnAnUnmountedVolumeIsKeptButNotListed() throws {
        let d = Defaults(); defer { d.cleanUp() }
        // A hand-made entry whose bookmark cannot resolve and whose path is on a volume that is not there.
        let entry = BookmarkStore.Entry(id: UUID(), bookmark: Data([1, 2, 3]), path: "/Volumes/NoSuchVolume-\(UUID().uuidString)/proj")
        d.defaults.set(try JSONEncoder().encode([entry]), forKey: "workspace.favorites")
        let store = FavoritesStore(defaults: d.defaults, seed: [])
        #expect(store.refresh().isEmpty)
        #expect(store.count == 1)
    }
}

struct RecentsStoreTests {
    @Test func newestFirstAndReopeningMovesToFront() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let a = try t.file("a.md"), b = try t.file("b.md"), c = try t.file("c.md")
        let store = RecentsStore(defaults: d.defaults)
        for url in [a, b, c] { store.noteOpened(url) }
        let idOfA = store.refresh()[2].id
        store.noteOpened(a)
        let list = store.refresh()
        #expect(list.map(\.url.lastPathComponent) == ["a.md", "c.md", "b.md"])
        #expect(list[0].id == idOfA)
    }

    @Test func capacityDropsTheOldest() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let store = RecentsStore(defaults: d.defaults, capacity: 3)
        for i in 1...5 { store.noteOpened(try t.file("f\(i).md")) }
        #expect(store.refresh().map(\.url.lastPathComponent) == ["f5.md", "f4.md", "f3.md"])
    }

    @Test func missingFilesAreNotRecordedAndDeletedOnesArePruned() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let store = RecentsStore(defaults: d.defaults)
        store.noteOpened(t.url.appending(path: "ghost.md"))
        #expect(store.count == 0)
        let a = try t.file("a.md"), b = try t.file("b.md")
        store.noteOpened(a); store.noteOpened(b)
        try FileManager.default.removeItem(at: a)
        #expect(store.refresh().map(\.url.lastPathComponent) == ["b.md"])
    }

    @Test func persistsAndClears() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        RecentsStore(defaults: d.defaults).noteOpened(try t.file("a.md"))
        let reopened = RecentsStore(defaults: d.defaults)
        #expect(reopened.refresh().map(\.url.lastPathComponent) == ["a.md"])
        reopened.clear()
        #expect(RecentsStore(defaults: d.defaults).count == 0)
    }

    @Test func aMovedFileIsFoundAndNotDuplicatedWhenOpenedAtItsNewPath() throws {
        let t = try TempDir(), d = Defaults(); defer { t.cleanUp(); d.cleanUp() }
        let old = try t.file("old.md")
        let store = RecentsStore(defaults: d.defaults)
        store.noteOpened(old)
        let new = t.url.appending(path: "new.md")
        try FileManager.default.moveItem(at: old, to: new)
        #expect(store.refresh().map(\.url.lastPathComponent) == ["new.md"])  // paths refreshed
        store.noteOpened(new)
        #expect(store.count == 1)
    }
}
