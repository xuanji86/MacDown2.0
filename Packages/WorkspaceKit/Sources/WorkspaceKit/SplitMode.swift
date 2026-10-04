import Foundation

/// Which panes of a window show. Three cases and no "neither": editor and preview can never both be hidden, whatever sets the mode
/// (toolbar cycle, preset, `macdown2 --preview-only`, a restored window record, the Settings default).
public enum SplitMode: String, CaseIterable, Codable, Sendable {
    case both, editorOnly, previewOnly

    /// UserDefaults key (in `AppDefaults.store`) of the Settings choice "Layout for new windows".
    public static let settingKey = "layout.newWindow"

    public var showsEditor: Bool { self != .previewOnly }
    public var showsPreview: Bool { self != .editorOnly }

    /// Toolbar button: both -> editor only -> preview only -> both.
    public var next: SplitMode {
        switch self {
        case .both: .editorOnly
        case .editorOnly: .previewOnly
        case .previewOnly: .both
        }
    }

    /// The Settings choice; a missing or unknown value is `.both`.
    public static func setting(in defaults: UserDefaults) -> SplitMode {
        defaults.string(forKey: settingKey).flatMap(SplitMode.init(rawValue:)) ?? .both
    }

    /// The layout a window starts with: the command line flag, else what its workspace folder last had, else its own saved record,
    /// else the Settings default. Anything that is not a valid mode (a corrupted record) counts as absent, so the result is always valid.
    public static func resolve(cli: SplitMode?, remembered: SplitMode?, restored: String?, setting: SplitMode) -> SplitMode {
        cli ?? remembered ?? restored.flatMap(SplitMode.init(rawValue:)) ?? setting
    }
}

/// The layout each workspace folder last had, so opening the same folder in a new window brings it back. Keyed by root `fileKey`,
/// newest first; a window with several roots writes one entry per root.
// lazy: the 50 most recently changed folders are remembered, older ones forget; upgrade = keep it in the folder's own bookmark entry.
public struct LayoutMemory: Equatable, Sendable {
    public static let defaultsKey = "layout.byWorkspace"
    public static let capacity = 50

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var mode: SplitMode
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = Array(entries.prefix(Self.capacity)) }

    /// Malformed rows are skipped, so one bad value cannot lose the rest.
    public init(defaults: UserDefaults) {
        let rows = defaults.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []
        self.init(entries: rows.compactMap { row in
            guard let key = row["key"], !key.isEmpty, let mode = row["mode"].flatMap(SplitMode.init(rawValue:)) else { return nil }
            return Entry(key: key, mode: mode)
        })
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(entries.map { ["key": $0.key, "mode": $0.mode.rawValue] }, forKey: Self.defaultsKey)
    }

    public mutating func remember(_ mode: SplitMode, forRoots keys: [String]) {
        for key in keys.reversed() {
            entries.removeAll { $0.key == key }
            entries.insert(Entry(key: key, mode: mode), at: 0)
        }
        entries = Array(entries.prefix(Self.capacity))
    }

    /// The layout of the first of `keys` that has one.
    public func mode(forRoots keys: [String]) -> SplitMode? {
        keys.lazy.compactMap { key in entries.first { $0.key == key }?.mode }.first
    }
}
