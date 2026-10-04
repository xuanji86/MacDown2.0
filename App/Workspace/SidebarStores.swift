import AppKit
import Foundation
import Observation
import WorkspaceKit

/// The sidebar's two app-wide lists, shared by every window: favorites (folders the user keeps) and recents (files opened
/// lately). Persisted through `AppDefaults.store` as bookmarks (WorkspaceKit); this class adds the observable copy the
/// views read.
@MainActor @Observable
final class SidebarStores {
    static let shared = SidebarStores()

    private(set) var favorites: [ResolvedBookmark] = []
    private(set) var recents: [URL] = []

    @ObservationIgnored private let favoritesStore: FavoritesStore
    @ObservationIgnored private let recentsStore: RecentsStore

    private init() {
        // An isolated launch must not seed Desktop / Documents / iCloud Drive: the one folder it may browse is its temp dir.
        let seed: [URL]
        if let isolation = AppDefaults.isolation {
            seed = isolation.allowedRoot.map { [$0] } ?? []
        } else {
            seed = FavoritesStore.standardLocations()
        }
        favoritesStore = FavoritesStore(defaults: AppDefaults.store, seed: seed)
        recentsStore = RecentsStore(defaults: AppDefaults.store)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SidebarStores.shared.refresh() }  // drops entries whose file went away meanwhile
        }
        refresh()
    }

    func refresh() {
        favorites = favoritesStore.refresh()
        recents = recentsStore.refresh().map(\.url)
    }

    func noteOpened(_ url: URL) {
        recentsStore.noteOpened(url)
        recents = recentsStore.refresh().map(\.url)
    }

    func clearRecents() {
        recentsStore.clear()
        recents = []
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.url.fileKey == url.fileKey } }

    /// false when it is already a favorite or the list is full (`FavoritesStore` never evicts silently).
    @discardableResult
    func addFavorite(_ url: URL, at index: Int? = nil) -> Bool {
        guard favoritesStore.add(url) else { return false }
        refresh()
        if let index, let added = favorites.first(where: { $0.url.fileKey == url.fileKey }) { moveFavorite(added.id, to: index) }
        return true
    }

    func removeFavorite(_ url: URL) {
        guard let entry = favorites.first(where: { $0.url.fileKey == url.fileKey }) else { return }
        favoritesStore.remove(id: entry.id)
        refresh()
    }

    func moveFavorite(_ id: UUID, to index: Int) {
        favoritesStore.move(id: id, toIndex: index)
        refresh()
    }

    var favoritesAreFull: Bool { favoritesStore.count >= favoritesStore.capacity }
}
