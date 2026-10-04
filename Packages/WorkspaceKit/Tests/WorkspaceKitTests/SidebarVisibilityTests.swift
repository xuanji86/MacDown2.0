import Foundation
import Testing
@testable import WorkspaceKit

struct SidebarVisibilityTests {
    private func suite() -> UserDefaults {
        let name = "SidebarVisibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aNewWindowStartsHidden() {
        #expect(SidebarVisibility.forNewWindow(defaults: suite()).isVisible == false)
    }

    @Test func theUsersLastChoiceIsWhatNewWindowsStartWith() {
        let defaults = suite()
        var first = SidebarVisibility.forNewWindow(defaults: defaults)
        first.userSet(true, defaults: defaults)
        #expect(first.isVisible)
        #expect(SidebarVisibility.forNewWindow(defaults: defaults).isVisible)
        first.userSet(false, defaults: defaults)
        #expect(!SidebarVisibility.forNewWindow(defaults: defaults).isVisible)
    }

    @Test func aWindowKeepsItsOwnStateWhenAnotherOneChanges() {
        let defaults = suite()
        var a = SidebarVisibility.forNewWindow(defaults: defaults)
        var b = SidebarVisibility.forNewWindow(defaults: defaults)
        a.userSet(true, defaults: defaults)
        #expect(a.isVisible && !b.isVisible)  // b only follows for windows created later
        b.isVisible = false
        #expect(SidebarVisibility.forNewWindow(defaults: defaults).isVisible)
    }

    @Test func enteringAWorkspaceShowsTheSidebarAndLeavingPutsItBack() {
        let defaults = suite()
        var hidden = SidebarVisibility.forNewWindow(defaults: defaults)
        hidden.workspaceEntered()
        #expect(hidden.isVisible && hidden.beforeWorkspace == false)
        hidden.workspaceLeft()
        #expect(!hidden.isVisible && hidden.beforeWorkspace == nil)

        var shown = SidebarVisibility(isVisible: true)
        shown.workspaceEntered()
        shown.workspaceLeft()
        #expect(shown.isVisible)
    }

    @Test func theWorkspaceDoesNotChangeWhatNewWindowsStartWith() {
        let defaults = suite()
        var w = SidebarVisibility.forNewWindow(defaults: defaults)
        w.workspaceEntered()
        w.workspaceLeft()
        #expect(defaults.object(forKey: SidebarVisibility.defaultsKey) == nil)
        #expect(!SidebarVisibility.forNewWindow(defaults: defaults).isVisible)
    }

    @Test func addingAFolderToAWorkspaceKeepsTheOriginalState() {
        var w = SidebarVisibility(isVisible: false)
        w.workspaceEntered()
        w.workspaceEntered()  // second folder
        w.workspaceLeft()
        #expect(!w.isVisible)
    }

    @Test func hidingTheSidebarInsideAWorkspaceIsHonouredUntilItCloses() {
        var w = SidebarVisibility(isVisible: true)
        w.workspaceEntered()
        w.isVisible = false
        #expect(!w.isVisible)
        w.workspaceLeft()
        #expect(w.isVisible)  // back to how it was before the workspace
    }

    @Test func leavingWithoutEnteringChangesNothing() {
        var w = SidebarVisibility(isVisible: true)
        w.workspaceLeft()
        #expect(w.isVisible)
    }

    @Test func theStateBeforeAWorkspaceSurvivesAWindowRestore() {
        var w = SidebarVisibility(isVisible: false)
        w.workspaceEntered()
        let state = WorkspaceWindowState(
            sidebarVisible: w.isVisible, workspaceRoots: [URL(filePath: "/p/book", directoryHint: .isDirectory)],
            sidebarVisibleBeforeWorkspace: w.beforeWorkspace)
        var restored = WindowRestoration.decode(WindowRestoration.encode([state]))[0]
        var v = SidebarVisibility(isVisible: restored.sidebarVisible, beforeWorkspace: restored.sidebarVisibleBeforeWorkspace)
        #expect(v.isVisible)
        v.workspaceLeft()
        #expect(!v.isVisible)
        restored.sidebarVisibleBeforeWorkspace = nil
        #expect(restored.sidebarVisible)
        // an older save without the field still decodes
        let old = Data(#"[{"id":"\#(UUID().uuidString)","sidebarVisible":true}]"#.utf8)
        #expect(WindowRestoration.decode(old).first?.sidebarVisibleBeforeWorkspace == nil)
    }
}
