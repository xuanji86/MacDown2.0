import Foundation

/// What `OpenRouter` needs to know about a window.
public struct WindowSnapshot: Equatable, Sendable {
    public let id: UUID
    /// `URL.fileKey` of the files open in it.
    public let openKeys: Set<String>

    public init(id: UUID, openKeys: Set<String>) {
        self.id = id
        self.openKeys = openKeys
    }
}

/// Where files opened from outside the window (Finder double click, drop on the Dock icon, Cmd-O, Open Recent) go.
public struct OpenPlan: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case window(UUID)
        case newWindow
    }

    public let target: Target
    /// Each file once, in the order given; the last one ends up active.
    public let urls: [URL]
    /// The ones the target window already has open (they are only activated).
    public let alreadyOpen: [URL]
}

/// PLAN Q15: every window is a workspace window. Files open as tabs in the frontmost window, a new window when there
/// is none; a file is open once per window, however often it is asked for.
public enum OpenRouter {
    /// `windows` is ordered front to back. nil when there is nothing to open.
    public static func plan(opening urls: [URL], windows: [WindowSnapshot]) -> OpenPlan? {
        var seen = Set<String>()
        let unique = urls.filter { $0.isFileURL && seen.insert($0.fileKey).inserted }
        guard !unique.isEmpty else { return nil }
        guard let front = windows.first else { return OpenPlan(target: .newWindow, urls: unique, alreadyOpen: []) }
        return OpenPlan(target: .window(front.id), urls: unique, alreadyOpen: unique.filter { front.openKeys.contains($0.fileKey) })
    }
}
