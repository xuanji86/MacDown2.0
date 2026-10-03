import Foundation

public struct ResolvedBookmark: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
}

/// Persistent, ordered list of locations kept as bookmark data (not paths), so an entry still finds its file after
/// it was moved or renamed. The app is not sandboxed; bookmarks are used anyway for exactly that reason.
/// Main-thread use; persistence goes through the injected `UserDefaults` (tests use a throwaway suite).
public class BookmarkStore {
    struct Entry: Codable, Equatable {
        let id: UUID
        var bookmark: Data
        var path: String  // last resolved location, used for de-duplication and to notice moves
    }

    let defaults: UserDefaults
    let key: String
    public let capacity: Int
    var entries: [Entry]

    init(persistingIn defaults: UserDefaults, key: String, capacity: Int) {
        self.defaults = defaults
        self.key = key
        self.capacity = capacity
        entries = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
    }

    public var count: Int { entries.count }

    func entry(for url: URL) -> Entry? {
        guard let bookmark = try? url.bookmarkData() else { return nil }  // throws for a file that does not exist
        return Entry(id: UUID(), bookmark: bookmark, path: url.fileKey)
    }

    func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Resolves every entry, in order. Entries whose file is gone (or sits in the Trash) are removed; entries that
    /// moved get their new path and a fresh bookmark. An entry on a volume that is not mounted right now is kept but
    /// left out of the result: an unplugged drive must not wipe the user's favorites.
    /// lazy: the offline test only knows /Volumes/<name>; network shares mounted elsewhere are treated as gone (upgrade: ask the bookmark for its volume URL).
    @discardableResult
    public func refresh() -> [ResolvedBookmark] {
        var result: [ResolvedBookmark] = []
        var kept: [Entry] = []
        for var entry in entries {
            var stale = false
            let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            if let url, FileManager.default.fileExists(atPath: url.path), !Self.isInTrash(url) {
                if stale || url.fileKey != entry.path {
                    if let fresh = try? url.bookmarkData() { entry.bookmark = fresh }
                    entry.path = url.fileKey
                }
                kept.append(entry)
                result.append(ResolvedBookmark(id: entry.id, url: url))
            } else if Self.isOnUnmountedVolume(entry.path) {
                kept.append(entry)
            }
        }
        if kept != entries {
            entries = kept
            save()
        }
        return result
    }

    static func isInTrash(_ url: URL) -> Bool { url.pathComponents.contains(".Trash") }

    static func isOnUnmountedVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }
}

/// Sidebar "Favorites": user-curated folders, in the user's order. Nothing is ever evicted silently: when full,
/// `add` refuses.
public final class FavoritesStore: BookmarkStore {
    public static let defaultCapacity = 50

    /// Desktop, Documents and iCloud Drive, whichever exist.
    public static func standardLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Desktop", "Documents", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `seed` is added once, the first time this store is created for `key`; a default the user removes stays removed.
    public init(defaults: UserDefaults = .standard, key: String = "workspace.favorites", capacity: Int = defaultCapacity, seed: [URL] = FavoritesStore.standardLocations()) {
        super.init(persistingIn: defaults, key: key, capacity: capacity)
        let seededKey = key + ".seeded"
        if !defaults.bool(forKey: seededKey) {
            for url in seed { add(url) }
            defaults.set(true, forKey: seededKey)
        }
    }

    /// Returns false when `url` is already a favorite, does not exist, or the list is full.
    @discardableResult
    public func add(_ url: URL) -> Bool {
        guard entries.count < capacity, !entries.contains(where: { $0.path == url.fileKey }), let entry = entry(for: url) else { return false }
        entries.append(entry)
        save()
        return true
    }

    public func move(id: UUID, toIndex index: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: min(max(index, 0), entries.count))
        save()
    }
}

/// Sidebar "Recents": most recently opened files first, capped (the oldest fall off).
public final class RecentsStore: BookmarkStore {
    public static let defaultCapacity = 20

    public init(defaults: UserDefaults = .standard, key: String = "workspace.recents", capacity: Int = defaultCapacity) {
        super.init(persistingIn: defaults, key: key, capacity: capacity)
    }

    /// Records an open: moves an existing entry to the front instead of duplicating it. A file that does not exist
    /// is not recorded.
    public func noteOpened(_ url: URL) {
        guard var entry = entry(for: url) else { return }
        if let old = entries.firstIndex(where: { $0.path == url.fileKey }) {
            entry = Entry(id: entries[old].id, bookmark: entry.bookmark, path: entry.path)  // keep the id the UI knows
            entries.remove(at: old)
        }
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }
}
