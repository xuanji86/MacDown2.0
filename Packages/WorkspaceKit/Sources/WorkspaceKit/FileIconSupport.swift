import Darwin
import Foundation

/// The two decisions behind the sidebar's Finder icons that need no AppKit: which cached icon is still good, and which files
/// may carry an icon of their own. The images themselves are drawn and cached by the app (`FileIcons`).

/// Tells whether an icon cached for a path is still current, without touching the disk (the check runs on the main thread
/// for every row). An icon is stamped with the paths' change counters when it is fetched; the folder watcher bumps the
/// counter of every directory whose listing changed, and a custom icon being set or removed shows up as exactly that
/// (an `Icon\r` file appearing, or the item's own metadata changing, which FSEvents reports on the item's directory).
public struct FileIconStamps: Sendable {
    /// What an icon was fetched under; equal to `stamp(of:)` now = still current.
    public struct Stamp: Equatable, Sendable {
        let epoch: Int
        let item: Int
        let parent: Int
        /// The `invalidateAll` generation it was made in.
        public var generation: Int { epoch }
    }

    private var epoch = 0
    private var counters: [String: Int] = [:]

    public init() {}

    /// The path's own counter and its parent folder's: bumping a directory renews its own icon (a folder's custom icon is
    /// written inside it) and every icon of its children.
    public func stamp(of path: String) -> Stamp {
        Stamp(epoch: epoch, item: counters[path] ?? 0, parent: counters[Self.parent(of: path)] ?? 0)
    }

    /// A fetch started under `stamp` may still store its result: no `invalidateAll` has happened since (a result from before it
    /// could carry the old default app's icon back into the cache).
    public func isCurrent(_ stamp: Stamp) -> Bool { stamp.epoch == epoch }

    /// Generation of the whole-cache invalidations; cached per-type icons are good only for the generation they were made in.
    public var generation: Int { epoch }

    /// Directories whose listing changed (a `FolderWatcher` batch).
    public mutating func invalidate(directories: [String]) {
        for path in directories { counters[path, default: 0] += 1 }
    }

    /// Everything may be stale (the window came forward after a time nobody watched, or a whole subtree was rescanned).
    public mutating func invalidateAll() { epoch += 1 }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}

public enum FinderInfo {
    /// `kHasCustomIcon` in the Finder flags: the item has an icon of its own (Get Info > paste, `NSWorkspace.setIcon`).
    /// One `getxattr` on `com.apple.FinderInfo`, so cheap enough to ask about every file before spending an icon lookup.
    public static func hasCustomIcon(atPath path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let n = getxattr(path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW)
        guard n >= 10 else { return false }
        let flags = UInt16(info[8]) << 8 | UInt16(info[9])  // big-endian, at offset 8 for files and folders alike
        return flags & 0x0400 != 0
    }
}
