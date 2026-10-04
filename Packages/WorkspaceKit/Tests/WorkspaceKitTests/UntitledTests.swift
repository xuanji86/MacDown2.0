import Foundation
import Testing
@testable import WorkspaceKit

struct UntitledNamesTests {
    @Test func numberingTakesTheSmallestFreeOne() {
        #expect(UntitledNames.firstFree(taken: []) == 1)
        #expect(UntitledNames.firstFree(taken: [1]) == 2)
        #expect(UntitledNames.firstFree(taken: [1, 2, 4]) == 3)
        #expect(UntitledNames.firstFree(taken: [2]) == 1)  // a closed "Untitled" is reused
        #expect([1, 2, 3, 12].map(UntitledNames.title) == ["Untitled", "Untitled 2", "Untitled 3", "Untitled 12"])
        #expect(UntitledNames.number(of: "Untitled") == 1 && UntitledNames.number(of: "Untitled 7") == 7)
        #expect(UntitledNames.number(of: "Untitled 1") == nil && UntitledNames.number(of: "notes.md") == nil)
    }

    @Test func theFirstHeadingNamesTheFile() {
        #expect(UntitledNames.suggestedFileName(for: "# Meeting notes\n\ntext") == "Meeting notes.md")
        #expect(UntitledNames.suggestedFileName(for: "intro line\n\n## Second level ##\n# later") == "Second level.md")
        #expect(UntitledNames.suggestedFileName(for: "") == "Untitled.md")
        #expect(UntitledNames.suggestedFileName(for: "just text, no heading") == "Untitled.md")
        #expect(UntitledNames.suggestedFileName(for: "#hashtag\n#!shebang") == "Untitled.md")  // not headings
        #expect(UntitledNames.suggestedFileName(for: "####### seven") == "Untitled.md")
    }

    @Test func codeFencesAndFrontMatterAreSkipped() {
        #expect(UntitledNames.suggestedFileName(for: "```sh\n# a comment\n```\n# Real") == "Real.md")
        #expect(UntitledNames.suggestedFileName(for: "~~~\n# x\n~~~\n") == "Untitled.md")
        #expect(UntitledNames.suggestedFileName(for: "---\ntitle: x\n# not a heading\n---\n# Body title") == "Body title.md")
    }

    @Test func markdownDecorationAndBadCharactersAreRemoved() {
        #expect(UntitledNames.suggestedFileName(for: "# **Bold** `code` [link](http://x.y)") == "Bold code link.md")
        #expect(UntitledNames.suggestedFileName(for: "# a/b: c\\d") == "ab cd.md")
        #expect(UntitledNames.suggestedFileName(for: "# ...  ") == "Untitled.md")
        #expect(UntitledNames.suggestedFileName(for: "# 第一章  开始\r\n") == "第一章 开始.md")
        #expect(UntitledNames.suggestedFileName(for: "# " + String(repeating: "x", count: 200)).count == 83)
    }
}

struct UntitledTabTests {
    private let doc = URL(filePath: "/ws/a.md")

    @Test func anUntitledKeyIsTheURLItself() {
        let id = UUID()
        let url = URL.untitled(id)
        #expect(url.isUntitled && !doc.isUntitled)
        #expect(url.fileKey == "untitled:\(id.uuidString.lowercased())")
        #expect(url.fileKey == URL.untitled(id).fileKey)
        #expect(doc.fileKey == "/ws/a.md")  // file keys are unchanged
    }

    @Test func untitledTabsBehaveLikeAnyOtherTab() {
        var s = TabSession()
        let u1 = URL.untitled(UUID()), u2 = URL.untitled(UUID())
        _ = s.doubleClick(u1)
        _ = s.doubleClick(u2)
        _ = s.doubleClick(u1)  // already open: only activates
        #expect(s.tabs.count == 2 && s.activeURL == u1 && s.previewURL == nil)
        _ = s.close(u1)
        #expect(s.activeURL == u2)
    }

    @Test func savingTurnsTheTabIntoAFileTabInPlace() {
        var s = TabSession()
        let u = URL.untitled(UUID())
        _ = s.doubleClick(URL(filePath: "/ws/x.md"))
        _ = s.doubleClick(u)
        _ = s.doubleClick(URL(filePath: "/ws/y.md"))
        s.moved(from: u, to: doc)
        #expect(s.tabs.map(\.id) == ["/ws/x.md", "/ws/a.md", "/ws/y.md"])
        #expect(s.tabs.allSatisfy { !$0.url.isUntitled })
    }

    @Test func savingOverAnOpenFileMergesInsteadOfDuplicating() {
        var s = TabSession()
        let u = URL.untitled(UUID())
        _ = s.doubleClick(doc)
        _ = s.doubleClick(u)
        s.moved(from: u, to: doc)  // saved on top of the file that is already open
        #expect(s.tabs.map(\.id) == ["/ws/a.md"] && s.activeURL == doc)
    }

    @Test func anUntitledTabLeavesTheCurrentLocationAlone() {
        var location = CurrentLocation(directory: URL(filePath: "/a/b", directoryHint: .isDirectory))
        location.follow(documentURL: URL.untitled(UUID()))
        #expect(location.directory?.fileKey == "/a/b")
        var none = CurrentLocation()
        none.follow(documentURL: URL.untitled(UUID()))
        #expect(none.directory == nil)
    }

    @Test func untitledTabsAreNotRestored() throws {
        var s = TabSession()
        _ = s.doubleClick(doc)
        _ = s.doubleClick(URL.untitled(UUID()))
        let state = WorkspaceWindowState(session: s.withoutUntitled)
        let back = WindowRestoration.decode(WindowRestoration.encode([state]))
        #expect(back.first?.session.tabs.map(\.id) == ["/ws/a.md"])
        #expect(back.first?.session.activeURL == doc)  // the active tab was the untitled one: falls back
        var only = TabSession()
        _ = only.doubleClick(URL.untitled(UUID()))
        #expect(only.withoutUntitled.tabs.isEmpty && only.withoutUntitled.activeURL == nil)
    }
}

@MainActor
struct UntitledControllerTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }
    private func make() -> (WorkspaceController, FakeBackend) {
        let backend = FakeBackend()
        return (WorkspaceController(ledger: DocumentLedger(), backend: backend), backend)
    }

    @Test func newUntitledOpensATabEachTime() {
        let (c, b) = make()
        c.newUntitled()
        c.newUntitled()
        #expect(c.session.tabs.count == 2 && c.session.tabs.allSatisfy { $0.url.isUntitled && !$0.isPreview })
        #expect(b.untitledCount == 2 && c.activeURL == c.session.tabs[1].url)
    }

    @Test func aBlankUntitledIsReplacedByAFileOpenedAnyWay() throws {
        for mode in [WorkspaceController.Mode.preview, .pinned] {
            let (c, b) = make()
            c.newUntitled()
            let blank = c.session.tabs[0].url
            try c.open(u("a"), as: mode)
            #expect(c.session.tabs.map(\.id) == ["/ws/a"])
            #expect(b.log.last == "unload \(blank.lastPathComponent)" || b.log.contains { $0.hasPrefix("unload") })
            #expect(c.activeURL == u("a"))
        }
    }

    @Test func anUntitledWithContentStays() throws {
        let (c, b) = make()
        c.newUntitled()
        let typed = c.session.tabs[0].url
        b.pristine.remove(typed.fileKey)  // the user typed
        try c.open(u("a"), as: .pinned)
        #expect(c.session.tabs.count == 2 && c.session.tabs[0].url == typed)
    }

    @Test func reopeningAnOpenFileKeepsTheBlankTab() throws {
        let (c, _) = make()
        try c.open(u("a"), as: .pinned)
        c.newUntitled()
        try c.open(u("a"), as: .pinned)  // only activates
        #expect(c.session.tabs.count == 2)
    }

    @Test func aFailedOpenKeepsTheBlankTab() {
        let (c, b) = make()
        c.newUntitled()
        b.unreadable = [u("bad").fileKey]
        #expect(throws: FakeBackend.Unreadable.self) { try c.open(u("bad"), as: .pinned) }
        #expect(c.session.tabs.count == 1 && c.session.tabs[0].url.isUntitled)
    }

    @Test func aWindowWithOnlyABlankUntitledCountsAsEmptyForRouting() throws {
        let (c, b) = make()
        c.newUntitled()
        let snapshot = WindowSnapshot(id: c.id, openKeys: c.openKeys, rootKeys: [])
        #expect(snapshot.openKeys.isEmpty)
        let folder = URL(filePath: "/ws/book", directoryHint: .isDirectory)
        #expect(OpenRouter.plan(opening: [folder], windows: [snapshot], isFolder: { _ in true })?.target == .window(c.id))
        b.pristine = []  // typed into: a real document now
        #expect(c.openKeys.count == 1)
        let busy = WindowSnapshot(id: c.id, openKeys: c.openKeys, rootKeys: [])
        #expect(OpenRouter.plan(opening: [folder], windows: [busy], isFolder: { _ in true })?.target == .newWindow)
    }

    @Test func closingTheLastBlankTabLeavesNothingToAsk() async {
        let (c, b) = make()
        c.newUntitled()
        #expect(await c.close(c.session.tabs[0].url))
        #expect(c.session.tabs.isEmpty && !b.log.contains { $0.hasPrefix("confirm") })
    }

    @Test func anUntitledWithContentAsksBeforeItCloses() async {
        let (c, b) = make()
        c.newUntitled()
        let url = c.session.tabs[0].url
        b.dirty = [url.fileKey]
        b.confirm = false
        #expect(await c.close(url) == false)
        #expect(c.session.tabs.count == 1)
        b.confirm = true
        #expect(await c.close(url))
        #expect(b.log.filter { $0.hasPrefix("confirm") }.count == 2 && c.session.tabs.isEmpty)
    }

    @Test func aSavedUntitledFollowsItsFileAndHandsOverTheLedgerKey() throws {
        let (c, _) = make()
        c.newUntitled()
        let old = c.session.tabs[0].url
        c.documentMoved(from: old, to: u("saved"))
        #expect(c.session.tabs.map(\.id) == ["/ws/saved"] && c.holds(u("saved")) && !c.holds(old))
    }
}
