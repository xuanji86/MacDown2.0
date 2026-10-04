import Foundation
import Testing
@testable import WorkspaceKit

@MainActor
struct WindowLifecycleTests {
    private func u(_ name: String) -> URL { URL(filePath: "/ws/\(name)") }

    @Test func blankWindowGetsUntitledOnlyWhenNothingElseIsComing() {
        #expect(WindowLifecycle.newWindowNeedsUntitled(tabs: 0, isWorkspace: false, pendingOpens: 0))
        #expect(!WindowLifecycle.newWindowNeedsUntitled(tabs: 1, isWorkspace: false, pendingOpens: 0))
        #expect(!WindowLifecycle.newWindowNeedsUntitled(tabs: 0, isWorkspace: true, pendingOpens: 0))
        #expect(!WindowLifecycle.newWindowNeedsUntitled(tabs: 0, isWorkspace: false, pendingOpens: 2))
        #expect(!WindowLifecycle.newWindowNeedsUntitled(tabs: 0, isWorkspace: false, pendingOpens: 0, restored: true))
    }

    @Test func dockClickOpensAWindowOnlyWhenThereIsNone() {
        #expect(WindowLifecycle.reopenNeedsWindow(workspaceWindows: 0, launching: false))
        #expect(!WindowLifecycle.reopenNeedsWindow(workspaceWindows: 1, launching: false))
        #expect(!WindowLifecycle.reopenNeedsWindow(workspaceWindows: 0, launching: true))
    }

    /// Closing the only tab empties the window; the way back in (Cmd-N, Open) works on that same controller.
    @Test func closingTheLastTabLeavesAnEmptyWindowThatTakesNewTabs() async throws {
        let backend = FakeBackend()
        let c = WorkspaceController(ledger: DocumentLedger(), backend: backend)
        c.newUntitled()
        let first = c.session.tabs[0].url
        #expect(await c.close(first))
        #expect(c.session.tabs.isEmpty)
        #expect(c.activeURL == nil)
        #expect(backend.log.last == "activate -")  // the window is told it shows nothing

        c.newUntitled()
        #expect(c.session.tabs.count == 1)
        try c.open(u("a.md"), as: .pinned)
        #expect(c.session.tabs.map(\.url.lastPathComponent) == ["a.md"])  // the pristine Untitled gives way to the first file
    }

    @Test func closingTheLastDirtyTabStillAsksAndCancelKeepsIt() async throws {
        let backend = FakeBackend()
        let c = WorkspaceController(ledger: DocumentLedger(), backend: backend)
        try c.open(u("a.md"), as: .pinned)
        backend.dirty.insert(u("a.md").fileKey)
        backend.confirm = false
        #expect(await c.close(u("a.md")) == false)
        #expect(c.session.tabs.count == 1)
        backend.confirm = true
        #expect(await c.close(u("a.md")))
        #expect(c.session.tabs.isEmpty)
    }
}
