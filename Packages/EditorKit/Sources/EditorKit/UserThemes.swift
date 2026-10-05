import CoreServices
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "themes")

/// Editor themes the user dropped into a folder (`~/Library/Application Support/MacDown2/Themes/`), in the same JSON format
/// as the built-in ones (PLAN 4.5). The folder is read by `UserThemes.load`; `UserThemeStore` keeps the result current.
public enum UserThemes {
    public static let suffix = " (User)"
    /// lazy: a theme file is a few KB; anything bigger than this is skipped unread instead of parsed (no streaming decoder).
    static let maxFileBytes = 256 * 1024

    /// `~/Library/Application Support/MacDown2/Themes`. A launch that must not touch the user's real files passes another
    /// folder to `UserThemeStore` instead.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MacDown2", directoryHint: .isDirectory).appending(path: "Themes", directoryHint: .isDirectory)
    }

    public struct Skipped: Equatable, Sendable {
        public var file: String
        public var reason: String
    }

    public struct Listing {
        /// In file-name order, names made unique (`resolveNames`).
        public var themes: [EditorTheme]
        /// Files that were not usable: unparseable, too big, unreadable, empty name.
        public var skipped: [Skipped]
    }

    /// Reads every `*.json` directly inside `directory` (not recursive, not hidden files). A missing or unreadable folder is an
    /// empty listing. A file that fails is skipped with a log line and never stops the others. `builtIn` are the names a user
    /// theme must not take over.
    public static func load(from directory: URL, builtIn: [EditorTheme] = ThemeLibrary.all) -> Listing {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return Listing(themes: [], skipped: [])
        }
        // Deterministic: the order of the listing is never the order of the picker.
        let files = entries.filter { $0.pathExtension.lowercased() == "json" }.sorted {
            let (a, b) = ($0.lastPathComponent.lowercased(), $1.lastPathComponent.lowercased())
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }
        var parsed: [EditorTheme] = []
        var skipped: [Skipped] = []
        func skip(_ url: URL, _ reason: String) {
            log.error("user theme \(url.lastPathComponent, privacy: .public) skipped: \(reason, privacy: .public)")
            skipped.append(Skipped(file: url.lastPathComponent, reason: reason))
        }
        for url in files {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { skip(url, "not a regular file"); continue }
            guard (values?.fileSize ?? 0) <= maxFileBytes else { skip(url, "larger than \(maxFileBytes / 1024) KB"); continue }
            do {
                var theme = try EditorTheme(json: Data(contentsOf: url))
                theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !theme.name.isEmpty else { skip(url, "empty theme name"); continue }
                parsed.append(theme)
            } catch {
                skip(url, String(describing: error))
            }
        }
        return Listing(themes: resolveNames(parsed, builtIn: builtIn.map(\.name)), skipped: skipped)
    }

    /// A user theme named like a built-in (or like an earlier user theme) is shown as "<name> (User)"; if that is taken too,
    /// "<name> (User 2)", "(User 3)" ... Decided in the order given, so the same files always give the same names. Built-ins
    /// never change name: a saved choice of "Solarized Dark" keeps meaning the built-in one.
    static func resolveNames(_ themes: [EditorTheme], builtIn: [String]) -> [EditorTheme] {
        var taken = Set(builtIn)
        return themes.map { theme in
            var theme = theme
            var candidate = theme.name
            var n = 1
            while taken.contains(candidate) {
                n += 1
                candidate = n == 2 ? theme.name + suffix : theme.name + " (User \(n - 1))"
            }
            taken.insert(candidate)
            theme.name = candidate
            return theme
        }
    }
}

/// The themes the pickers list: the built-ins, then the user's. Watches the user folder (FSEvents) and reloads on any change,
/// so a theme file saved while the app runs shows up, edits take effect and a deleted theme disappears. Read `all` / `revision`
/// from SwiftUI to be updated.
@MainActor @Observable
public final class UserThemeStore {
    public let directory: URL
    public private(set) var userThemes: [EditorTheme] = []
    public private(set) var skipped: [UserThemes.Skipped] = []
    /// Counts reloads: a theme's name stays while its colours change, so views that cache a theme compare this.
    public private(set) var revision = 0

    private let builtIn: [EditorTheme]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Built-ins first, in their own order, then the user's in file-name order.
    public var all: [EditorTheme] { builtIn + userThemes }

    public init(directory: URL, builtIn: [EditorTheme] = ThemeLibrary.all) {
        self.directory = directory
        self.builtIn = builtIn
    }

    isolated deinit { stopWatching() }

    /// Loads the folder now and starts watching it. Idempotent; call again after the folder was created.
    public func start() {
        reload()
        startWatching()
    }

    public func reload() {
        let listing = UserThemes.load(from: directory, builtIn: builtIn)
        userThemes = listing.themes
        skipped = listing.skipped
        revision += 1
    }

    /// Creates the folder if it is missing (the first "Reveal Themes Folder" click) and makes sure it is watched.
    @discardableResult
    public func ensureDirectory() -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            log.error("cannot create the themes folder: \(String(describing: error), privacy: .public)")
            return false
        }
        startWatching()
        return true
    }

    // MARK: FSEvents

    // lazy: events are coalesced for 0.3 s and every event reloads the whole folder (a handful of small files); no per-file diff
    private func startWatching() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<UserThemeStore>.fromOpaque(info).takeUnretainedValue()
            // The stream is scheduled on the main queue, so this runs on the main actor.
            MainActor.assumeIsolated { store.scheduleReload() }
        }
        // The real path: FSEvents reports paths with /private/var resolved, and watches the folder, not what a symlink points at.
        let path = directory.resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else {
            log.error("cannot watch the themes folder")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// An editor saving a file writes a temp file, renames it, touches attributes: several events for one change.
    private func scheduleReload() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}
