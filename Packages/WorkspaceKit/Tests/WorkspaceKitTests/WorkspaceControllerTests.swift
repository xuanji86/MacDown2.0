import Foundation
import Testing
@testable import WorkspaceKit

/// Records everything the controller asks of the document layer.
@MainActor
final class FakeBackend: DocumentBackend {
    var log: [String] = []
    var dirty = Set<String>()
    var unreadable = Set<String>()
    var confirm = true
    var loaded = Set<String>()

    struct Unreadable: Error {}

    func load(_ url: URL) throws {
        if unreadable.contains(url.fileKey) { throw Unreadable() }
        loaded.insert(url.fileKey)
    }
    func isDirty(_ url: URL) -> Bool { dirty.contains(url.fileKey) }
    func confirmClose(_ url: URL, in window: UUID) async -> Bool {
        log.append("confirm \(url.lastPathComponent)")
        return confirm
    }
    func unload(_ url: URL) {
        loaded.remove(url.fileKey)
        log.append("unload \(url.lastPathComponent)")
    }
    func didActivate(_ url: URL?, in window: UUID) { log.append("activate \(url?.lastPathComponent ?? "-")") }
}

@MainActor
struct WorkspaceControllerTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }
    private func names(_ c: WorkspaceController) -> [String] { c.session.tabs.map { $0.url.lastPathComponent + ($0.isPreview ? "~" : "") } }
    private func make() -> (WorkspaceController, FakeBackend, DocumentLedger) {
        let backend = FakeBackend(), ledger = DocumentLedger()
        return (WorkspaceController(ledger: ledger, backend: backend), backend, ledger)
    }

    @Test func opensLoadAndActivateInOrderAndReplacingAPreviewClosesTheOldOneLast() throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .preview)
        try c.open(u("b"), as: .preview)
        #expect(names(c) == ["b~"])
        #expect(b.log == ["activate a", "activate b", "unload a"])  // never without a current document in between
    }

    @Test func anUnreadableFileChangesNothing() {
        let (c, b, _) = make()
        b.unreadable = [u("bad").fileKey]
        #expect(throws: FakeBackend.Unreadable.self) { try c.open(u("bad"), as: .pinned) }
        #expect(c.session.tabs.isEmpty)
        #expect(b.log.isEmpty)
    }

    @Test func aPreviewWithUnsavedChangesIsPinnedNotReplaced() throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .preview)
        b.dirty = [u("a").fileKey]
        try c.open(u("b"), as: .preview)
        #expect(names(c) == ["a", "b~"])
        #expect(!b.log.contains("unload a"))
    }

    @Test func theSameFileIsOpenOnceAndOnlyActivated() throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        try c.open(u("b"), as: .pinned)
        b.log = []
        try c.open(u("a"), as: .pinned)
        try c.open(u("a"), as: .preview)
        #expect(names(c) == ["a", "b"])
        #expect(c.activeURL == u("a"))
        #expect(b.log == ["activate a"])
    }

    @Test func pinOnlyTouchesThePreview() throws {
        let (c, _, _) = make()
        try c.open(u("a"), as: .preview)
        c.pin(u("other"))
        #expect(names(c) == ["a~"])
        c.pin(u("a"))
        #expect(names(c) == ["a"])
    }

    @Test func closingTheActiveTabActivatesTheNeighbourThenUnloads() async throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        try c.open(u("b"), as: .pinned)
        try c.open(u("c"), as: .pinned)
        c.activate(u("b"))
        b.log = []
        #expect(await c.close(u("b")))
        #expect(names(c) == ["a", "c"])
        #expect(c.activeURL == u("c"))
        #expect(b.log == ["unload b", "activate c"])
    }

    @Test func closingTheLastTabLeavesTheWindowWithoutADocument() async throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        b.log = []
        #expect(await c.close(u("a")))
        #expect(b.log == ["unload a", "activate -"])
    }

    @Test func aDirtyDocumentAsksBeforeTheTabGoesAndCancelKeepsIt() async throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        b.dirty = [u("a").fileKey]
        b.confirm = false
        #expect(await c.close(u("a")) == false)
        #expect(names(c) == ["a"])
        #expect(b.log.contains("confirm a"))
        #expect(!b.log.contains("unload a"))
        b.confirm = true
        #expect(await c.close(u("a")))
        #expect(c.session.tabs.isEmpty)
    }

    @Test func aDocumentShownInTwoWindowsClosesWithTheLastOne() async throws {
        let backend = FakeBackend(), ledger = DocumentLedger()
        let one = WorkspaceController(ledger: ledger, backend: backend), two = WorkspaceController(ledger: ledger, backend: backend)
        try one.open(u("a"), as: .pinned)
        try two.open(u("a"), as: .pinned)
        backend.dirty = [u("a").fileKey]
        backend.log = []
        #expect(await one.close(u("a")))  // the other window still shows it: no prompt, no unload
        #expect(!backend.log.contains("confirm a") && !backend.log.contains("unload a"))
        #expect(await two.close(u("a")))
        #expect(backend.log.contains("confirm a") && backend.log.contains("unload a"))
    }

    @Test func closeAllStopsAtTheFirstCancel() async throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        try c.open(u("b"), as: .pinned)
        try c.open(u("c"), as: .pinned)
        b.dirty = [u("b").fileKey]
        b.confirm = false
        #expect(await c.closeAll() == false)
        #expect(names(c) == ["b", "c"])  // a was clean and is gone; b stopped it
        b.confirm = true
        #expect(await c.closeAll())
        #expect(c.session.tabs.isEmpty)
    }

    @Test func detachLetsGoOfEverythingExceptWhatAnotherWindowShows() throws {
        let backend = FakeBackend(), ledger = DocumentLedger()
        let one = WorkspaceController(ledger: ledger, backend: backend), two = WorkspaceController(ledger: ledger, backend: backend)
        try one.open(u("a"), as: .pinned)
        try one.open(u("b"), as: .pinned)
        try two.open(u("b"), as: .pinned)
        backend.log = []
        one.detach()
        #expect(backend.log.contains("unload a"))
        #expect(!backend.log.contains("unload b"))
        #expect(one.session.tabs.isEmpty)
    }

    @Test func restoreDropsFilesThatNoLongerOpenAndActivatesTheSavedTab() throws {
        let (c, b, ledger) = make()
        var saved = TabSession()
        _ = saved.doubleClick(u("a")); _ = saved.doubleClick(u("gone")); _ = saved.singleClick(u("p"))
        _ = saved.activate(u("gone"))
        b.unreadable = [u("gone").fileKey]
        c.restore(saved)
        #expect(names(c) == ["a", "p~"])
        #expect(c.activeURL == u("a"))  // the saved active tab is gone: first remaining one
        #expect(ledger.holders(of: u("a").fileKey) == [c.id])
        #expect(b.log == ["activate a"])
    }

    @Test func tabSwitchingWrapsAndNumberNineIsTheLastTab() throws {
        let (c, _, _) = make()
        for n in ["a", "b", "c"] { try c.open(u(n), as: .pinned) }
        c.select(offset: 1)
        #expect(c.activeURL == u("a"))
        c.select(offset: -1)
        #expect(c.activeURL == u("c"))
        c.select(number: 1)
        #expect(c.activeURL == u("a"))
        c.select(number: 9)
        #expect(c.activeURL == u("c"))
        c.select(number: 2)
        #expect(c.activeURL == u("b"))
    }

    @Test func aMovedDocumentKeepsItsTabAndIsReactivated() throws {
        let (c, b, _) = make()
        try c.open(u("a"), as: .pinned)
        b.log = []
        c.documentMoved(from: u("a"), to: u("renamed"))
        #expect(names(c) == ["renamed"])
        #expect(b.log == ["activate renamed"])
    }
}

@MainActor
struct DocumentLedgerTests {
    @Test func releaseReportsTheLastHolder() {
        let l = DocumentLedger()
        let w1 = UUID(), w2 = UUID()
        l.hold("/a", by: w1); l.hold("/a", by: w2)
        #expect(!l.release("/a", by: w1))
        #expect(l.release("/a", by: w2))
        #expect(l.holders(of: "/a").isEmpty)
    }

    @Test func rekeyMovesAllHolders() {
        let l = DocumentLedger()
        let w1 = UUID(), w2 = UUID()
        l.hold("/a", by: w1); l.hold("/a", by: w2)
        l.rekey("/a", to: "/b")
        #expect(l.holders(of: "/b") == [w1, w2])
        #expect(l.holders(of: "/a").isEmpty)
        #expect(l.keys(heldBy: w1) == ["/b"])
    }
}
