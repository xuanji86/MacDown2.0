import Foundation

/// The folders the document popover's "Where:" menu offers: where the file is now (or will be saved), the workspace folders,
/// the folders of recent documents, then Desktop, Documents and Downloads. "Other…" (a folder panel) is the UI's own item.
public enum WhereChoices {
    public static let limit = 8

    /// Existing folders only, no duplicates (by `fileKey`), `current` always first, at most `limit`. `exists` is injectable for tests.
    public static func folders(
        current: URL, workspace: [URL], recents: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (URL) -> Bool = { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
    ) -> [URL] {
        let standard = ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0, directoryHint: .isDirectory) }
        var seen = Set<String>()
        var out: [URL] = []
        for url in [current] + workspace + recents + standard where exists(url) && seen.insert(url.fileKey).inserted {
            out.append(url)
        }
        // `current` stays even when it is not a plain existing folder (a deleted one): the menu must show where the file is.
        if out.first?.fileKey != current.fileKey { out.insert(current, at: 0) }
        return Array(out.prefix(limit))
    }
}
