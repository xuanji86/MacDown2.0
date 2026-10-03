import Foundation
import Testing
@testable import WorkspaceKit

struct TabSessionTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }
    private func names(_ s: TabSession) -> [String] { s.tabs.map { $0.url.lastPathComponent + ($0.isPreview ? "~" : "") } }

    @Test func singleClickOpensAPreviewAndTheNextOneReplacesItInPlace() {
        var s = TabSession()
        #expect(s.singleClick(u("a")) == [.opened(u("a")), .activated(u("a"))])
        #expect(names(s) == ["a~"])
        #expect(s.singleClick(u("b")) == [.opened(u("b")), .activated(u("b")), .closed(u("a"))])
        #expect(names(s) == ["b~"])
        #expect(s.activeURL == u("b"))
    }

    @Test func doubleClickPinsAndTheNextSingleClickOpensANewPreviewBesideIt() {
        var s = TabSession()
        _ = s.singleClick(u("a"))
        #expect(s.doubleClick(u("a")) == [.pinned(u("a"))])  // already active: just pinned
        #expect(names(s) == ["a"])
        _ = s.singleClick(u("b"))
        #expect(names(s) == ["a", "b~"])
        _ = s.singleClick(u("c"))
        #expect(names(s) == ["a", "c~"])
    }

    @Test func doubleClickOnAFileNotOpenYetOpensItPinnedAndLeavesThePreviewAlone() {
        var s = TabSession()
        _ = s.singleClick(u("a"))
        _ = s.doubleClick(u("b"))
        #expect(names(s) == ["a~", "b"])
        #expect(s.activeURL == u("b"))
        #expect(s.previewURL == u("a"))
    }

    @Test func editingPinsThePreviewOnce() {
        var s = TabSession()
        _ = s.singleClick(u("a"))
        #expect(s.edited(u("a")) == [.pinned(u("a"))])
        #expect(s.edited(u("a")).isEmpty)
        #expect(s.edited(u("elsewhere")).isEmpty)
        _ = s.singleClick(u("b"))  // the edited file survives
        #expect(names(s) == ["a", "b~"])
    }

    @Test func openingAFileTwiceActivatesTheExistingTab() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b"))
        #expect(s.singleClick(u("a")) == [.activated(u("a"))])  // no preview tab, a stays pinned
        #expect(names(s) == ["a", "b"])
        #expect(s.doubleClick(u("b")) == [.activated(u("b"))])
        #expect(names(s) == ["a", "b"])
        #expect(s.singleClick(u("b")).isEmpty)  // already active: nothing to do
    }

    @Test func singleClickOnTheCurrentPreviewKeepsItAPreview() {
        var s = TabSession()
        _ = s.singleClick(u("a")); _ = s.singleClick(u("b"))
        #expect(s.singleClick(u("b")).isEmpty)
        #expect(names(s) == ["b~"])
    }

    @Test func dedupeIgnoresTrailingSlashesAndDotSegments() {
        var s = TabSession()
        _ = s.doubleClick(URL(filePath: "/ws/dir/a.md"))
        _ = s.singleClick(URL(filePath: "/ws/dir/../dir/a.md"))
        #expect(s.tabs.count == 1)
    }

    @Test func newTabsOpenToTheRightOfTheActiveOne() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b")); _ = s.doubleClick(u("c"))
        _ = s.activate(u("a"))
        _ = s.doubleClick(u("d"))
        #expect(names(s) == ["a", "d", "b", "c"])
    }

    @Test func closingTheActiveTabActivatesItsRightNeighbourElseTheLeftOne() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b")); _ = s.doubleClick(u("c"))
        _ = s.activate(u("b"))
        #expect(s.close(u("b")) == [.closed(u("b")), .activated(u("c"))])
        #expect(s.close(u("c")) == [.closed(u("c")), .activated(u("a"))])
        #expect(s.close(u("a")) == [.closed(u("a"))])
        #expect(s.activeURL == nil)
        #expect(s.tabs.isEmpty)
    }

    @Test func closingAnInactiveTabKeepsTheActiveOne() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b"))
        #expect(s.close(u("a")) == [.closed(u("a"))])
        #expect(s.activeURL == u("b"))
        #expect(s.close(u("nope")).isEmpty)
    }

    @Test func closingThePreviewFreesTheSlot() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.singleClick(u("b"))
        _ = s.close(u("b"))
        #expect(s.previewURL == nil)
        _ = s.singleClick(u("c"))
        #expect(names(s) == ["a", "c~"])
    }

    @Test func aRenamedFileKeepsItsTabAndItsFlags() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.singleClick(u("b"))
        s.moved(from: u("b"), to: u("b2"))
        #expect(names(s) == ["a", "b2~"])
        #expect(s.activeURL == u("b2"))
        _ = s.singleClick(u("b2"))  // the new name is what dedupes now
        #expect(names(s) == ["a", "b2~"])
    }

    @Test func movingOntoAnOpenFileMergesTheTabs() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b"))
        s.moved(from: u("b"), to: u("a"))
        #expect(names(s) == ["a"])
        #expect(s.activeURL == u("a"))
    }

    @Test func survivesACodableRoundTripForWindowRestoration() throws {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.singleClick(u("b"))
        let back = try JSONDecoder().decode(TabSession.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.activeURL == u("b"))
    }
}

struct CurrentLocationTests {
    @Test func followsTheActiveDocumentsFolder() {
        var loc = CurrentLocation()
        #expect(loc.directory == nil && loc.parent == nil && loc.segments().isEmpty)
        loc.follow(documentURL: URL(filePath: "/Users/me/Notes/a.md"))
        #expect(loc.directory?.fileKey == "/Users/me/Notes")
        #expect(loc.parent?.fileKey == "/Users/me")
    }

    @Test func anUntitledDocumentKeepsTheLocation() {
        var loc = CurrentLocation()
        loc.follow(documentURL: URL(filePath: "/a/b/c.md"))
        loc.follow(documentURL: nil)
        #expect(loc.directory?.fileKey == "/a/b")
    }

    @Test func navigatingUpSticksUntilTheActiveDocumentChanges() {
        var loc = CurrentLocation()
        loc.follow(documentURL: URL(filePath: "/a/b/c.md"))
        loc.navigate(to: loc.parent!)
        #expect(loc.directory?.fileKey == "/a")
        loc.follow(documentURL: URL(filePath: "/x/y/z.md"))
        #expect(loc.directory?.fileKey == "/x/y")
    }

    @Test func segmentsRunFromTheRootDownToTheCurrentFolder() {
        let loc = CurrentLocation(directory: URL(filePath: "/Users/me/Notes", directoryHint: .isDirectory))
        let segments = loc.segments(rootTitle: "Macintosh HD")
        #expect(segments.map(\.title) == ["Macintosh HD", "Users", "me", "Notes"])
        #expect(segments.map(\.url.fileKey) == ["/", "/Users", "/Users/me", "/Users/me/Notes"])
    }

    @Test func theRootHasOneSegmentAndNoParent() {
        let loc = CurrentLocation(directory: URL(filePath: "/"))
        #expect(loc.segments().map(\.title) == ["/"])
        #expect(loc.parent == nil)
    }

    @Test func aDocumentAtTheRootFollowsToTheRoot() {
        var loc = CurrentLocation()
        loc.follow(documentURL: URL(filePath: "/a.md"))
        #expect(loc.directory?.fileKey == "/")
    }
}
