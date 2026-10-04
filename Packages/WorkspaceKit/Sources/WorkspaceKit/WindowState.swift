import Foundation

/// Which sidebar page a window shows (the segmented control at the top of the sidebar).
public enum SidebarSection: String, Codable, CaseIterable, Sendable {
    case files, search, outline
}

/// What a workspace window restores after a relaunch: its tabs (files, which one is a preview, which is active), the
/// sidebar page and visibility, and the editor/preview split. Plain values so they encode into one JSON blob.
public struct WorkspaceWindowState: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var session: TabSession
    public var sidebarSection: SidebarSection
    public var sidebarVisible: Bool
    /// `SplitLayout.Mode.rawValue`; the app validates it.
    public var splitMode: String
    public var editorFraction: Double
    /// Workspace folders; empty = browse mode.
    public var workspaceRoots: [URL]
    /// The sidebar's "All" switch (every file type, dimmed when not Markdown).
    public var showAllFiles: Bool
    /// `sidebarVisible` as it was before the workspace was opened (restored when it closes); nil outside a workspace.
    public var sidebarVisibleBeforeWorkspace: Bool?

    public init(
        id: UUID = UUID(), session: TabSession = TabSession(), sidebarSection: SidebarSection = .files,
        sidebarVisible: Bool = true, splitMode: String = "both", editorFraction: Double = 0.5,
        workspaceRoots: [URL] = [], showAllFiles: Bool = false, sidebarVisibleBeforeWorkspace: Bool? = nil
    ) {
        self.sidebarVisibleBeforeWorkspace = sidebarVisibleBeforeWorkspace
        self.workspaceRoots = workspaceRoots
        self.showAllFiles = showAllFiles
        self.id = id
        self.session = session
        self.sidebarSection = sidebarSection
        self.sidebarVisible = sidebarVisible
        self.splitMode = splitMode
        self.editorFraction = editorFraction
    }

    // Tolerant: a field added or renamed by another version must not lose the whole window.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            session: (try? c.decodeIfPresent(TabSession.self, forKey: .session)) ?? TabSession(),
            sidebarSection: (try? c.decodeIfPresent(SidebarSection.self, forKey: .sidebarSection)) ?? .files,
            sidebarVisible: try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true,
            splitMode: try c.decodeIfPresent(String.self, forKey: .splitMode) ?? "both",
            editorFraction: min(max(try c.decodeIfPresent(Double.self, forKey: .editorFraction) ?? 0.5, 0), 1),
            workspaceRoots: (try? c.decodeIfPresent([URL].self, forKey: .workspaceRoots)) ?? [],
            showAllFiles: (try? c.decodeIfPresent(Bool.self, forKey: .showAllFiles)) ?? false,
            sidebarVisibleBeforeWorkspace: try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisibleBeforeWorkspace)
        )
    }
}

/// All open windows, front to back, as stored in UserDefaults.
public enum WindowRestoration {
    public static let maxWindows = 20

    public static func encode(_ states: [WorkspaceWindowState]) -> Data? {
        try? JSONEncoder().encode(states.prefix(maxWindows).map { $0 })
    }

    /// Empty for no data or garbage; an entry that does not decode is skipped, the rest survive.
    public static func decode(_ data: Data?) -> [WorkspaceWindowState] {
        guard let data, let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return all.compactMap(\.state).prefix(maxWindows).map { $0 }
    }

    private struct Lossy: Decodable {
        let state: WorkspaceWindowState?
        init(from decoder: any Decoder) throws { state = try? WorkspaceWindowState(from: decoder) }
    }
}
