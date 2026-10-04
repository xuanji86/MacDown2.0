import Foundation

/// Whether a window's sidebar is showing. Windows start with it hidden (a clean editor and preview, like the original
/// MacDown); what the user last chose with Cmd-\ or the toolbar button becomes the start state of windows opened after
/// that. Entering workspace mode shows it (the user asked for a folder) and leaving restores what it was before.
public struct SidebarVisibility: Equatable, Sendable {
    /// UserDefaults key (in `AppDefaults.store`) of the last choice the user made.
    public static let defaultsKey = "sidebar.visible"

    public var isVisible: Bool
    /// The state to go back to when the workspace closes; nil outside a workspace.
    public private(set) var beforeWorkspace: Bool?

    public init(isVisible: Bool, beforeWorkspace: Bool? = nil) {
        self.isVisible = isVisible
        self.beforeWorkspace = beforeWorkspace
    }

    /// A new window: hidden until the user has chosen otherwise.
    public static func forNewWindow(defaults: UserDefaults) -> SidebarVisibility {
        SidebarVisibility(isVisible: defaults.object(forKey: defaultsKey) as? Bool ?? false)
    }

    /// The user toggled the sidebar (Cmd-\, toolbar button): this window keeps it, new windows follow it.
    public mutating func userSet(_ visible: Bool, defaults: UserDefaults) {
        isVisible = visible
        defaults.set(visible, forKey: Self.defaultsKey)
    }

    /// A folder was opened as a workspace: show the sidebar. Adding another folder keeps the state from before the first.
    public mutating func workspaceEntered() {
        if beforeWorkspace == nil { beforeWorkspace = isVisible }
        isVisible = true
    }

    public mutating func workspaceLeft() {
        if let before = beforeWorkspace { isVisible = before }
        beforeWorkspace = nil
    }
}
