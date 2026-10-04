import Testing
@testable import EditorKit

struct RevealTrackerTests {
    private func request(_ key: String) -> RevealRequest { RevealRequest(key: key, line: 3, columns: 1..<4, focus: true) }

    @Test func aResultForTheShownFileIsCarriedOutAtOnce() {
        var tracker = RevealTracker()
        _ = tracker.bound(key: "/a.md")
        #expect(tracker.request(request("/a.md")) == request("/a.md"))
        #expect(tracker.pending == nil)
    }

    @Test func aResultWaitsForItsFileToBeBound() {
        var tracker = RevealTracker()
        _ = tracker.bound(key: "/a.md")
        #expect(tracker.request(request("/b.md")) == nil)
        #expect(tracker.bound(key: "/b.md") == request("/b.md"))
    }

    @Test func aResultForAFileThatNeverComesUpIsDropped() {
        var tracker = RevealTracker()
        _ = tracker.bound(key: "/a.md")
        _ = tracker.request(request("/b.md"))
        #expect(tracker.bound(key: "/c.md") == nil)
        #expect(tracker.bound(key: "/b.md") == nil)  // too late: it must not fire on a later switch
    }

    @Test func aFirstSavedOrRenamedDocumentGetsItsKeyUpdated() {
        var tracker = RevealTracker()
        _ = tracker.bound(key: nil)  // an Untitled
        _ = tracker.request(request("/saved.md"))
        #expect(tracker.sync(key: "/saved.md") == request("/saved.md"))  // the same document, now a file
        #expect(tracker.shownKey == "/saved.md")
        #expect(tracker.request(request("/saved.md")) == request("/saved.md"))
    }

    @Test func anUnchangedKeyDoesNotDropAWaitingResult() {
        var tracker = RevealTracker()
        _ = tracker.bound(key: "/a.md")
        _ = tracker.request(request("/b.md"))
        #expect(tracker.sync(key: "/a.md") == nil)
        #expect(tracker.pending == request("/b.md"))
    }
}
