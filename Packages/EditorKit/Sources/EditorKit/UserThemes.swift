import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "themes")

/// Editor themes the user dropped into a folder (`~/Library/Application Support/MacDown2/Themes/`), in the same JSON format
/// as the built-in ones (PLAN 4.5). The folder is read by `UserThemes.load`; `UserThemeStore` keeps the result current (whoever
/// watches the folder calls `rescan()`).
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
        /// Every file that took part (name and bytes) plus the skipped ones: equal fingerprints mean nothing a theme is made of changed.
        var fingerprint = Data()
    }

    /// Reads every `*.json` directly inside `directory` (not recursive, not hidden files; a symlink to a file counts as that file).
    /// A missing or unreadable folder is an empty listing. A file that fails is skipped with a log line and never stops the others.
    /// `builtIn` are the names a user theme must not take over.
    public static func load(from directory: URL, builtIn: [EditorTheme] = ThemeLibrary.all) -> Listing {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return Listing(themes: [], skipped: [])
        }
        // Deterministic: the order of the listing is never the order of the picker.
        let files = entries.filter { $0.pathExtension.lowercased() == "json" }.sorted {
            let (a, b) = ($0.lastPathComponent.lowercased(), $1.lastPathComponent.lowercased())
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }
        var parsed: [EditorTheme] = []
        var skipped: [Skipped] = []
        var fingerprint = Data()
        func skip(_ url: URL, _ reason: String) {
            log.error("user theme \(url.lastPathComponent, privacy: .public) skipped: \(reason, privacy: .public)")
            skipped.append(Skipped(file: url.lastPathComponent, reason: reason))
            fingerprint.append(Data("\(url.lastPathComponent)\u{0}\(reason)\u{0}".utf8))
        }
        for url in files {
            let target = url.resolvingSymlinksInPath()  // a theme kept elsewhere and linked into the folder
            let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { skip(url, "not a regular file"); continue }
            guard (values?.fileSize ?? 0) <= maxFileBytes else { skip(url, "larger than \(maxFileBytes / 1024) KB"); continue }
            do {
                let data = try Data(contentsOf: target)
                var theme = try EditorTheme(json: data)
                theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !theme.name.isEmpty else { skip(url, "empty theme name"); continue }
                parsed.append(theme)
                fingerprint.append(Data("\(url.lastPathComponent)\u{0}".utf8))
                fingerprint.append(data)
            } catch {
                skip(url, describe(error))
            }
        }
        return Listing(themes: resolveNames(parsed, builtIn: builtIn.map(\.name)), skipped: skipped, fingerprint: fingerprint)
    }

    /// One line a person can act on ("colors.background: colour must be #RRGGBB ...") instead of the decoder's whole dump.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context): return "missing \"\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context): return path(context).isEmpty ? "not valid JSON" : "\(path(context)): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }

    /// A user theme named like a built-in (or like an earlier user theme) is shown as "<name> (User)"; if that is taken too,
    /// "<name> (User 2)", "(User 3)" ... Decided in the order given, so the same files always give the same names. Built-ins
    /// never change name: a saved choice of "Solarized Dark" keeps meaning the built-in one. A `counterpart` that names a
    /// sibling that had to be renamed follows the rename (the pair was written together), so "follow the system" still finds it;
    /// one that names a built-in, or a sibling that kept its name, stays.
    static func resolveNames(_ themes: [EditorTheme], builtIn: [String]) -> [EditorTheme] {
        var taken = Set(builtIn)
        var kept = Set<String>()
        var renamed: [String: String] = [:]  // original name -> the first sibling's new name
        var result = themes.map { theme -> EditorTheme in
            var theme = theme
            let original = theme.name
            var candidate = original
            var n = 1
            while taken.contains(candidate) {
                n += 1
                candidate = n == 2 ? original + suffix : original + " (User \(n - 1))"
            }
            taken.insert(candidate)
            theme.name = candidate
            if candidate == original { kept.insert(original) } else if renamed[original] == nil { renamed[original] = candidate }
            return theme
        }
        for i in result.indices {
            if let counterpart = result[i].counterpart, !kept.contains(counterpart), let new = renamed[counterpart] { result[i].counterpart = new }
        }
        return result
    }
}

/// The themes the pickers list: the built-ins, then the user's. `rescan()` re-reads the folder; whoever watches it (the app, with
/// `FolderWatcher`) calls that on every change, so a theme file saved while the app runs shows up, edits take effect and a deleted
/// theme disappears. Read `all` / `revision` from SwiftUI to be updated.
@MainActor @Observable
public final class UserThemeStore {
    public let directory: URL
    public private(set) var userThemes: [EditorTheme] = []
    public private(set) var skipped: [UserThemes.Skipped] = []
    /// Counts reloads that changed something. A theme's name stays while its colours change, so views that cache a theme compare this.
    public private(set) var revision = 0

    private let builtIn: [EditorTheme]
    @ObservationIgnored private var fingerprint = Data()

    /// Built-ins first, in their own order, then the user's in file-name order.
    public var all: [EditorTheme] { builtIn + userThemes }

    public init(directory: URL, builtIn: [EditorTheme] = ThemeLibrary.all) {
        self.directory = directory
        self.builtIn = builtIn
    }

    /// Reads the folder. Nothing is published, and `revision` stays, when the files say the same as last time (a `.DS_Store` written,
    /// a file touched): every open editor would otherwise re-apply its theme and lay the whole document out again.
    public func rescan() {
        let listing = UserThemes.load(from: directory, builtIn: builtIn)
        guard listing.fingerprint != fingerprint else { return }
        fingerprint = listing.fingerprint
        userThemes = listing.themes
        skipped = listing.skipped
        revision += 1
    }

    /// Creates the folder if it is missing (the first "Reveal Themes Folder" click).
    @discardableResult
    public func ensureDirectory() -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            log.error("cannot create the themes folder: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }
}
