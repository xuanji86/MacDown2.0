import Foundation

/// How `macdown2 --preview-only <files>` tells the app which layout the files' window gets, whether the app is running or not.
///
/// The tool writes a small file naming the paths and the layout just before it runs `open`; the app reads (and deletes) the file
/// that names a path it is asked to open. No Apple Events (so no Automation prompt), no URL scheme, and a cold launch works the
/// same as a running app, because the file is there before the open request is. A file is only a hint: it names paths already being
/// opened, carries one of three fixed values, and goes stale after `lifetime`.
public enum LayoutHints {
    public static let lifetime: TimeInterval = 120
    private static let maxFileSize = 1_000_000

    private struct Hint: Codable {
        var mode: String
        var paths: [String]
        var at: TimeInterval
    }

    /// `~/Library/Caches/io.github.xuanji86.MacDown2/layout-hints/<suite or app>`: an isolated test instance has its own folder, so it
    /// never takes a hint meant for the real app (or the other way round).
    public static func directory(home: URL, suite: String?) -> URL {
        let scope = suite.flatMap { $0.isEmpty || $0.contains("/") || $0 == "." || $0 == ".." ? nil : $0 } ?? "app"
        return home.appending(path: "Library/Caches/io.github.xuanji86.MacDown2/layout-hints/\(scope)", directoryHint: .isDirectory)
    }

    /// `keys` are `URL.fileKey`s of the files and folders about to be opened. Also removes hints nobody took in time.
    public static func write(_ mode: SplitMode, for keys: [String], in directory: URL, now: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = fresh(in: directory, now: now)  // drops the stale ones
        let data = try JSONEncoder().encode(Hint(mode: mode.rawValue, paths: keys, at: now.timeIntervalSince1970))
        try data.write(to: directory.appending(path: UUID().uuidString + ".json"), options: .atomic)
    }

    /// The layout asked for one of `keys` (newest hint wins); the hints that match are used up. nil = none.
    public static func take(for keys: [String], in directory: URL, now: Date = Date()) -> SplitMode? {
        let wanted = Set(keys)
        var found: (at: TimeInterval, mode: SplitMode)?
        for (file, hint, mode) in fresh(in: directory, now: now) where hint.paths.contains(where: wanted.contains) {
            try? FileManager.default.removeItem(at: file)
            if found == nil || hint.at > found!.at { found = (hint.at, mode) }
        }
        return found?.mode
    }

    /// The valid, unexpired hints; expired, oversized and undecodable files are deleted on the way.
    private static func fresh(in directory: URL, now: Date) -> [(URL, Hint, SplitMode)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) <= maxFileSize,
                  let data = try? Data(contentsOf: file), let hint = try? JSONDecoder().decode(Hint.self, from: data),
                  let mode = SplitMode(rawValue: hint.mode), abs(now.timeIntervalSince1970 - hint.at) <= lifetime
            else {
                try? fm.removeItem(at: file)
                return nil
            }
            return (file, hint, mode)
        }
    }
}
