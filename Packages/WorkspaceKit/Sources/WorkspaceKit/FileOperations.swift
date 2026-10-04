import Foundation

/// The sidebar's file operations as plain functions: where a new item goes, what it is called, whether a name is
/// acceptable. Moving to the Trash is not here: the app does it with `NSWorkspace.recycle` (never a delete), after
/// closing the tabs that hold the file.
public enum FileOperations {
    public enum Failure: Error, Equatable {
        case invalidName
        case exists(String)
        /// Home, its standard folders, the volume root and its direct children (also when reached through a symlink).
        case protected(String)
    }

    /// Where "New File" / "New Folder" put the item: inside a folder, next to a file.
    public static func targetDirectory(for url: URL, isDirectory: Bool) -> URL {
        isDirectory ? url : url.deletingLastPathComponent()
    }

    private static func candidate(_ n: Int, in directory: URL, base: String, ext: String?, isDirectory: Bool) -> URL {
        let stem = n == 1 ? base : "\(base) \(n)"
        return directory.appending(path: ext.map { "\(stem).\($0)" } ?? stem, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// `Untitled.md`, then `Untitled 2.md`, `Untitled 3.md`… the first one that does not exist. Only a preview of the
    /// name: `createFile` / `createFolder` claim a name atomically.
    public static func uniqueChild(in directory: URL, base: String, ext: String?, isDirectory: Bool, fileManager: FileManager = .default) -> URL {
        var n = 1
        while fileManager.fileExists(atPath: candidate(n, in: directory, base: base, ext: ext, isDirectory: isDirectory).path) { n += 1 }
        return candidate(n, in: directory, base: base, ext: ext, isDirectory: isDirectory)
    }

    /// Creates the first free name with an exclusive create (`O_EXCL` / `mkdir`): losing a race to another process moves
    /// on to the next name instead of overwriting what it made.
    private static func createExclusively(in directory: URL, base: String, ext: String?, isDirectory: Bool) throws -> URL {
        for n in 1...10_000 {
            let url = candidate(n, in: directory, base: base, ext: ext, isDirectory: isDirectory)
            let made: Bool
            if isDirectory {
                made = mkdir(url.path, 0o777) == 0
            } else {
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
                made = fd >= 0
                if made { close(fd) }
            }
            if made { return url }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path]) }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
    }

    public static func createFile(in directory: URL) throws -> URL {
        try createExclusively(in: directory, base: "Untitled", ext: "md", isDirectory: false)
    }

    public static func createFolder(in directory: URL) throws -> URL {
        try createExclusively(in: directory, base: "Untitled Folder", ext: nil, isDirectory: true)
    }

    /// Whether two URLs name the very same directory entry (same volume and inode), however they are spelled.
    public static func isSameEntry(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    /// A file name the file system and the user would accept: trimmed, not empty, not a path, `.`/`..`, not too long.
    public static func validName(_ newName: String) throws -> String {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw Failure.invalidName }
        return name
    }

    /// Where `url` ends up when renamed to `newName`; throws for a protected folder, for a name the file system or the user
    /// would not want (empty, a path, `.`/`..`, too long) and for one already taken by another item. A destination that
    /// differs only in case is accepted only when it is the same directory entry (a case-insensitive volume): on a
    /// case-sensitive one, `notes.md` → `NOTES.md` next to a distinct `NOTES.md` is a collision.
    /// - Parameter isSameEntry: injectable for tests (a case-sensitive volume is not at hand there).
    public static func destination(
        renaming url: URL, to newName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default, isSameEntry: (URL, URL) -> Bool = FileOperations.isSameEntry
    ) throws -> URL {
        try destination(moving: url, as: newName, into: url.deletingLastPathComponent(), home: home, fileManager: fileManager, isSameEntry: isSameEntry)
    }

    /// Where `url` ends up when it is called `newName` and lives in `directory` (the document popover's Name and Where): the
    /// rules of `destination(renaming:to:)`, with the folder chosen too.
    public static func destination(
        moving url: URL, as newName: String, into directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default, isSameEntry: (URL, URL) -> Bool = FileOperations.isSameEntry
    ) throws -> URL {
        try requireUnprotected(url, home: home)
        let name = try validName(newName)
        let target = directory.appending(path: name, directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
        if target.path != url.path, fileManager.fileExists(atPath: target.path) {
            let isCaseOnly = target.path.lowercased() == url.path.lowercased()
            guard isCaseOnly, isSameEntry(url, target) else { throw Failure.exists(name) }
        }
        return target
    }

    /// Where a document that has no file yet is saved as `newName` in `directory`; throws for a bad name and for one taken.
    public static func destination(newFile newName: String, in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let name = try validName(newName)
        let target = directory.appending(path: name, directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: target.path) { throw Failure.exists(name) }
        return target
    }

    /// Renames a file or folder that no document holds open (open ones go through `NSDocument.move`).
    @discardableResult
    public static func rename(_ url: URL, to newName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) throws -> URL {
        let target = try destination(renaming: url, to: newName, home: home, fileManager: fileManager)
        if target.path == url.path { return url }
        if target.path.lowercased() == url.path.lowercased() {
            // A case-only change: go through a temporary name (`moveItem` never replaces, so a collision rolls back).
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
    /// the volume root and its direct children. Judged by the real location as well as by the spelling, so a workspace
    /// holding a symlink to the home folder does not expose `link/Documents`.
    public static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        isProtected(key: url.fileKey, homeKey: home.fileKey) || isProtected(key: realKey(url), homeKey: realKey(home))
    }

    /// The mutation boundary (rename, trash): the menu does not offer these actions, and this refuses them whoever asks.
    public static func requireUnprotected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        if isProtected(url, home: home) { throw Failure.protected(url.lastPathComponent) }
    }

    private static func isProtected(key: String, homeKey h: String) -> Bool {
        if key == "/" || key == h { return true }
        let standard = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]
        return standard.contains { key == h + "/" + $0 } || key.split(separator: "/").count <= 1
    }

    /// `fileKey` of the symlink-free location (symlinks of the whole path resolved).
    private static func realKey(_ url: URL) -> String {
        let key = url.fileKey
        let real = FolderWatcher.realPath(key)
        return real == key ? key : URL(fileURLWithPath: real).fileKey
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
