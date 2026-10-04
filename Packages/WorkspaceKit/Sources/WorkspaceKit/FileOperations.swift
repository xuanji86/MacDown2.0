import Foundation

/// The sidebar's file operations as plain functions: where a new item goes, what it is called, whether a name is
/// acceptable. Moving to the Trash is not here: the app does it with `NSWorkspace.recycle` (never a delete), after
/// closing the tabs that hold the file.
public enum FileOperations {
    public enum Failure: Error, Equatable {
        case invalidName
        case exists(String)
    }

    /// Where "New File" / "New Folder" put the item: inside a folder, next to a file.
    public static func targetDirectory(for url: URL, isDirectory: Bool) -> URL {
        isDirectory ? url : url.deletingLastPathComponent()
    }

    /// `Untitled.md`, then `Untitled 2.md`, `Untitled 3.md`… the first one that does not exist.
    public static func uniqueChild(in directory: URL, base: String, ext: String?, isDirectory: Bool, fileManager: FileManager = .default) -> URL {
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? base : "\(base) \(n)"
            return directory.appending(path: ext.map { "\(stem).\($0)" } ?? stem, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        }
        var n = 1
        while fileManager.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    public static func createFile(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = uniqueChild(in: directory, base: "Untitled", ext: "md", isDirectory: false, fileManager: fileManager)
        guard fileManager.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return url
    }

    public static func createFolder(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = uniqueChild(in: directory, base: "Untitled Folder", ext: nil, isDirectory: true, fileManager: fileManager)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Where `url` ends up when renamed to `newName`; throws for a name the file system or the user would not want
    /// (empty, a path, `.`/`..`, too long) and for one already taken by another item. A change of case only is fine.
    public static func destination(renaming url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw Failure.invalidName }
        let target = url.deletingLastPathComponent().appending(path: name, directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
        let isCaseOnly = target.path.lowercased() == url.path.lowercased()
        if !isCaseOnly, fileManager.fileExists(atPath: target.path) { throw Failure.exists(name) }
        return target
    }

    /// Renames a file or folder that no document holds open (open ones go through `NSDocument.move`).
    @discardableResult
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        let target = try destination(renaming: url, to: newName, fileManager: fileManager)
        if target.path == url.path { return url }
        if target.path.lowercased() == url.path.lowercased() {
            // A case-only change on a case-insensitive volume: go through a temporary name.
            let temp = url.deletingLastPathComponent().appending(path: ".rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temp)
            do { try fileManager.moveItem(at: temp, to: target) } catch {
                try? fileManager.moveItem(at: temp, to: url)
                throw error
            }
        } else {
            try fileManager.moveItem(at: url, to: target)
        }
        return target
    }

    /// Folders that must never be renamed or trashed from the sidebar: the user's home and its standard folders,
    /// the volume root and its direct children.
    public static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let key = url.fileKey
        let h = home.fileKey
        if key == "/" || key == h { return true }
        let standard = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]
        return standard.contains { key == h + "/" + $0 } || key.split(separator: "/").count <= 1
    }
}

/// What the right-click menu offers (design 02: the same menu for files and folders; a favorite's last item is "remove").
public enum FileAction: Equatable, Sendable {
    case revealInFinder, copyPath, newFile, newFolder, rename, moveToTrash, addToFavorites, removeFromFavorites
}

public enum SidebarContextMenu {
    /// - Parameters:
    ///   - isAnchor: a favorite entry or a workspace root: renaming or trashing it would pull the floor from under the sidebar.
    ///   - isFavorite: the folder is in the favorites list.
    public static func actions(for url: URL, isDirectory: Bool, isAnchor: Bool, isFavorite: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FileAction] {
        var out: [FileAction] = [.revealInFinder, .copyPath, .newFile, .newFolder]
        if !isAnchor, !FileOperations.isProtected(url, home: home) { out += [.rename, .moveToTrash] }
        if isDirectory { out.append(isFavorite ? .removeFromFavorites : .addToFavorites) }
        return out
    }
}
