import Foundation
import Testing
@testable import WorkspaceKit

struct OpenRouterTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }
    private let front = WindowSnapshot(id: UUID(), openKeys: ["/ws/a"])
    private let back = WindowSnapshot(id: UUID(), openKeys: ["/ws/b"])

    @Test func noWindowMeansANewOne() {
        let plan = OpenRouter.plan(opening: [u("a")], windows: [])
        #expect(plan == OpenPlan(target: .newWindow, urls: [u("a")], alreadyOpen: []))
    }

    @Test func filesGoToTheFrontmostWindowEvenWhenAnotherOneHasThem() {
        let plan = OpenRouter.plan(opening: [u("b"), u("c")], windows: [front, back])
        #expect(plan?.target == .window(front.id))
        #expect(plan?.urls == [u("b"), u("c")])
        #expect(plan?.alreadyOpen == [])
    }

    @Test func aFileTheFrontWindowHasIsReportedAndStaysInTheList() {
        let plan = OpenRouter.plan(opening: [u("a"), u("z")], windows: [front, back])
        #expect(plan?.alreadyOpen == [u("a")])
        #expect(plan?.urls == [u("a"), u("z")])
    }

    @Test func duplicatesCollapseAndSpellingsOfThePathAreTheSameFile() {
        let plan = OpenRouter.plan(opening: [u("a"), URL(filePath: "/ws/x/../a"), u("a")], windows: [])
        #expect(plan?.urls == [u("a")])
    }

    @Test func nothingToOpenIsNoPlan() {
        #expect(OpenRouter.plan(opening: [], windows: [front]) == nil)
        #expect(OpenRouter.plan(opening: [URL(string: "https://example.com/a.md")!], windows: [front]) == nil)
    }
}

struct WindowStateTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }

    private func sample() -> WorkspaceWindowState {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.singleClick(u("b"))
        _ = s.activate(u("a"))
        return WorkspaceWindowState(session: s, sidebarSection: .outline, sidebarVisible: false, splitMode: "editorOnly", editorFraction: 0.3)
    }

    @Test func roundTripKeepsTabsPreviewActiveSidebarAndSplit() throws {
        let state = sample()
        let back = WindowRestoration.decode(WindowRestoration.encode([state, WorkspaceWindowState()]))
        #expect(back.count == 2)
        #expect(back[0] == state)
        #expect(back[0].session.tabs.map(\.isPreview) == [false, true])
        #expect(back[0].session.activeURL == u("a"))
    }

    @Test func garbageAndEmptyDataGiveNoWindows() {
        #expect(WindowRestoration.decode(nil).isEmpty)
        #expect(WindowRestoration.decode(Data("not json".utf8)).isEmpty)
        #expect(WindowRestoration.decode(Data("{}".utf8)).isEmpty)
    }

    @Test func oneBrokenEntryDoesNotTakeTheOthersDown() throws {
        let state = sample()
        let good = try #require(WindowRestoration.encode([state]))
        var json = try #require(String(data: good, encoding: .utf8))
        json.insert(contentsOf: "42,", at: json.index(after: json.startIndex))
        let back = WindowRestoration.decode(Data(json.utf8))
        #expect(back == [state])
    }

    @Test func missingFieldsFallBackToDefaultsAndBadValuesAreClamped() throws {
        let state = try JSONDecoder().decode(WorkspaceWindowState.self, from: Data(#"{"editorFraction": 7, "sidebarSection": "nonsense"}"#.utf8))
        #expect(state.sidebarSection == .files)
        #expect(state.sidebarVisible)
        #expect(state.editorFraction == 1)
        #expect(state.splitMode == "both")
        #expect(state.session.tabs.isEmpty)
    }

    @Test func aSessionIsNormalisedOnDecode() throws {
        let json = """
        {"tabs":[{"url":"file:///ws/a","isPreview":true},{"url":"file:///ws/a","isPreview":false},
                 {"url":"file:///ws/b","isPreview":true},{"url":"file:///ws/c","isPreview":false}],"activeID":"/ws/zzz"}
        """
        let s = try JSONDecoder().decode(TabSession.self, from: Data(json.utf8))
        #expect(s.tabs.map(\.id) == ["/ws/a", "/ws/b", "/ws/c"])  // duplicate dropped
        #expect(s.tabs.filter(\.isPreview).count == 1)  // a stays the preview, b is demoted
        #expect(s.activeURL == u("a"))  // unknown active tab -> first
    }

    @Test func atMostTwentyWindowsAreKept() {
        let many = (0..<30).map { _ in WorkspaceWindowState() }
        #expect(WindowRestoration.decode(WindowRestoration.encode(many)).count == WindowRestoration.maxWindows)
    }
}

struct TabSessionReorderTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }
    private func names(_ s: TabSession) -> [String] { s.tabs.map { $0.url.lastPathComponent + ($0.isPreview ? "~" : "") } }

    @Test func movingReordersAndPinsAPreview() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b")); _ = s.singleClick(u("p"))
        #expect(names(s) == ["a", "b", "p~"])
        #expect(s.move(u("p"), to: 0) == [.pinned(u("p"))])
        #expect(names(s) == ["p", "a", "b"])
        #expect(s.move(u("a"), to: 99).isEmpty)  // clamped, already pinned
        #expect(names(s) == ["p", "b", "a"])
        #expect(s.move(u("nope"), to: 0).isEmpty)
    }

    @Test func moveKeepsTheActiveTab() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b"))
        _ = s.move(u("b"), to: 0)
        #expect(s.activeURL == u("b"))
    }

    @Test func prunedKeepsOrderAndFixesTheActiveTab() {
        var s = TabSession()
        _ = s.doubleClick(u("a")); _ = s.doubleClick(u("b")); _ = s.doubleClick(u("c"))
        let p = s.pruned { $0 != u("c") }
        #expect(names(p) == ["a", "b"])
        #expect(p.activeURL == u("a"))
        #expect(s.pruned { _ in false }.activeURL == nil)
    }
}

struct FileKeyTests {
    @Test func theSymlinkedSystemFoldersHaveOneKeyWhetherOrNotTheFileExists() {
        #expect(URL(filePath: "/private/tmp/x/a.md").fileKey == "/tmp/x/a.md")
        #expect(URL(filePath: "/tmp/x/a.md").fileKey == "/tmp/x/a.md")
        #expect(URL(filePath: "/private/var/folders/z/a.md").fileKey == "/var/folders/z/a.md")
        #expect(URL(filePath: "/private/etc").fileKey == "/etc")
        #expect(URL(filePath: "/private/other/a.md").fileKey == "/private/other/a.md")
        #expect(URL(filePath: "/Users/me/x/../a.md/").fileKey == "/Users/me/a.md")
    }

    @Test func aTabKeepsItsIdentityWhenItsFileGoesAway() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "keytest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "a.md")
        try Data("x".utf8).write(to: file)
        var s = TabSession()
        _ = s.doubleClick(file)
        try FileManager.default.removeItem(at: dir)
        s.moved(from: file, to: dir.appending(path: "b.md"))
        #expect(s.activeURL?.lastPathComponent == "b.md")  // the active tab was recognised although its file is gone
    }
}
