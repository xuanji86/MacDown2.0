import Foundation

/// Which folders the search panel looks in.
public enum SearchScope {
    /// Workspace mode: the workspace folders. Browse mode (no workspace): the sidebar's "current location", the folder of
    /// the active document, since there is nothing else the user has named. nil when there is nothing sensible to search:
    /// no folder yet, or the volume root / one of its direct children (`/`, `/Users`), where a search would read the disk.
    public static func roots(workspace: WorkspaceFolders, location: URL?) -> [URL] {
        if workspace.isActive { return workspace.roots }
        guard let location, !isTooBroad(location) else { return [] }
        return [location]
    }

    public static func isTooBroad(_ url: URL) -> Bool { url.standardizedFileURL.pathComponents.count <= 2 }

    /// "MyBook" / "2 个文件夹" / the location's name: what the panel says it is searching in.
    public static func title(of roots: [URL]) -> String {
        switch roots.count {
        case 0: return ""
        case 1: return roots[0].lastPathComponent
        default: return "\(roots.count) 个文件夹"
        }
    }
}
