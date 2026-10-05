import AppKit
import EditorKit
import Foundation
import Observation
import WorkspaceKit

/// The app's one `UserThemeStore`: built-in themes plus the files in `~/Library/Application Support/MacDown2/Themes/`.
/// An isolated launch (`Scripts/run-isolated.sh`) never reads the user's real folder: it looks in `.macdown2-themes` inside its
/// own root (or a temp folder named after its suite when it has none), so a test can drop theme files there.
@MainActor
enum UserThemeFolder {
    static let directory: URL = {
        guard let isolation = AppDefaults.isolation else { return UserThemes.defaultDirectory }
        let base = isolation.allowedRoot ?? FileManager.default.temporaryDirectory.appending(path: isolation.suiteName, directoryHint: .isDirectory)
        return base.appending(path: ".macdown2-themes", directoryHint: .isDirectory)
    }()

    /// Read on first use and kept current by `watcher`.
    static let store: UserThemeStore = {
        let store = UserThemeStore(directory: directory)
        store.rescan()
        startWatching()
        return store
    }()

    // The watcher lives as long as the app. It reports the folder even before it exists (the root is watched), so creating it by
    // hand, or with Reveal, and dropping a theme in is picked up.
    private static let watcher = FolderWatcher(roots: [directory], debounce: 0.3, ignoreSelf: false, watchRoot: true) { _ in
        Task { @MainActor in store.rescan() }
    }

    private static func startWatching() { watcher.start() }

    /// Settings ▸ Editor ▸ Reveal Themes Folder: creates the folder when it is not there yet, then shows it in Finder.
    static func reveal() {
        guard store.ensureDirectory() else { return }
        startWatching()  // a stream that could not start for a folder that was missing gets another go
        NSWorkspace.shared.open(directory)
    }

    /// `ThemeLibrary.resolve` over the built-in and user themes.
    static func resolve(name: String, followSystem: Bool, systemIsDark: Bool) -> EditorTheme {
        ThemeLibrary.resolve(name: name, followSystem: followSystem, systemIsDark: systemIsDark, among: store.all)
    }
}

/// The theme list as an `ObservableObject`: SwiftUI does not re-run a `Commands` body for `@Observable` reads, so the menu bar would
/// keep the list it was built with. Views read `UserThemeFolder.store` directly; the View menu observes this.
@MainActor
final class ThemeMenuList: ObservableObject {
    static let shared = ThemeMenuList()
    @Published private(set) var themes: [EditorTheme] = UserThemeFolder.store.all

    private init() { track() }

    private func track() {
        withObservationTracking { _ = UserThemeFolder.store.all } onChange: {
            Task { @MainActor [self] in
                themes = UserThemeFolder.store.all
                track()
            }
        }
    }
}
