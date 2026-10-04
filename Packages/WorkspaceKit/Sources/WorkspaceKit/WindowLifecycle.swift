import Foundation

/// When a workspace window appears. Closing tabs or windows never ends the app (only Cmd-Q does): the last tab leaves its
/// window open showing the empty state, the last window leaves the app running, and these two rules say what brings a window back.
public enum WindowLifecycle {
    /// A window that comes up with nothing in it (a launch with nothing to restore or open, Cmd-Option-N, the Dock icon with no
    /// window) gets a blank untitled tab, as the original MacDown does. A workspace window stays as it is (its tree is the way in),
    /// and so does one that is about to receive files that were asked for, and a window restored from the last session without
    /// a tab (untitled tabs are not restored): that one shows the empty state, as it did when it was last seen.
    public static func newWindowNeedsUntitled(tabs: Int, isWorkspace: Bool, pendingOpens: Int, restored: Bool = false) -> Bool {
        tabs == 0 && !isWorkspace && pendingOpens == 0 && !restored
    }

    /// The Dock icon was clicked (or the app was opened again) and the system asks whether to do its default: a new window is
    /// wanted when no workspace window exists at all. A minimized window is still a window: the default brings it back.
    /// While the app is still launching the first window is on its way.
    public static func reopenNeedsWindow(workspaceWindows: Int, launching: Bool) -> Bool {
        workspaceWindows == 0 && !launching
    }
}
