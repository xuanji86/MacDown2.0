import Foundation

/// What `OpenRouter` needs to know about a window.
public struct WindowSnapshot: Equatable, Sendable {
    public let id: UUID
    /// `URL.fileKey` of the files open in it.
    public let openKeys: Set<String>
    /// `URL.fileKey` of the workspace folders it shows; empty = browse mode.
    public let rootKeys: Set<String>

    public init(id: UUID, openKeys: Set<String>, rootKeys: Set<String> = []) {
        self.id = id
        self.openKeys = openKeys
        self.rootKeys = rootKeys
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
    /// Folders to enter workspace mode with (added as roots of the target window; one that is already a root is a no-op).
    public let folders: [URL]

    init(target: Target, urls: [URL], alreadyOpen: [URL], folders: [URL] = []) {
        self.target = target
        self.urls = urls
        self.alreadyOpen = alreadyOpen
        self.folders = folders
    }
}

/// PLAN Q15: every window is a workspace window. Files open as tabs in the frontmost window, a new window when there
/// is none; a file is open once per window, however often it is asked for.
///
/// A folder (Finder drop, `macdown2 .`, Open Folder…) enters workspace mode: in the window that already has it as a
/// root, else the frontmost window when that one is browsing with nothing open, else a new window. Several folders
/// become roots of the same window; files in the same request open there as tabs.
public enum OpenRouter {
    /// A directory, but not a package (`.app`, `.pages` count as files, as in the tree). A symlink to a folder (`/tmp`, a synced
    /// `~/notes`) is its target: resource values would describe the link itself.
    public static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// `windows` is ordered front to back. nil when there is nothing to open.
    public static func plan(opening urls: [URL], windows: [WindowSnapshot], isFolder: (URL) -> Bool = OpenRouter.isFolder) -> OpenPlan? {
        var seen = Set<String>()
        let unique = urls.filter { $0.isFileURL && seen.insert($0.fileKey).inserted }
        guard !unique.isEmpty else { return nil }
        let folders = unique.filter(isFolder)
        let folderKeys = Set(folders.map(\.fileKey))
        let files = unique.filter { !folderKeys.contains($0.fileKey) }
        let target: OpenPlan.Target
        if folders.isEmpty {
            target = windows.first.map { .window($0.id) } ?? .newWindow
        } else if let has = windows.first(where: { !$0.rootKeys.isDisjoint(with: folderKeys) }) {
            target = .window(has.id)
        } else if let front = windows.first, front.rootKeys.isEmpty, front.openKeys.isEmpty {
            target = .window(front.id)
        } else {
            target = .newWindow
        }
        var open: Set<String> = []
        if case .window(let id) = target { open = windows.first { $0.id == id }?.openKeys ?? [] }
        return OpenPlan(target: target, urls: files, alreadyOpen: files.filter { open.contains($0.fileKey) }, folders: folders)
    }
}
