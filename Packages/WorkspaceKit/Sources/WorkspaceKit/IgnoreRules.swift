import Foundation

extension URL {
    /// Identity of a file system location: standardized path without a trailing slash. `URL ==` tells `/a/b` from
    /// `/a/b/`, so every dictionary and comparison in this module goes through this key instead.
    ///
    /// Stable for the life of a tab: `standardizedFileURL` drops the `/private` of `/private/tmp|var|etc` only while the file
    /// exists, so a renamed or deleted file would get a different key than it was opened with. The prefix is dropped here
    /// by rule instead.
    public var fileKey: String {
        let path = standardizedFileURL.path
        guard path.hasPrefix("/private/") else { return path }
        let rest = path.dropFirst("/private".count)
        return ["/tmp", "/var", "/etc"].contains { rest == $0 || rest.hasPrefix($0 + "/") } ? String(rest) : path
    }
}

/// Names the tree and the watcher skip (PLAN 4.11). `names` match exactly, `suffixes` only match directories
/// (Quarto/Pandoc's `*_files/` render output).
public struct IgnoreRules: Sendable, Equatable, Codable {
    public var names: Set<String>
    public var suffixes: Set<String>

    public init(names: Set<String>, suffixes: Set<String>) {
        self.names = names
        self.suffixes = suffixes
    }

    public static let `default` = IgnoreRules(
        names: [".git", "node_modules", "_site", "_book", "_freeze", ".quarto", ".Rproj.user", "__pycache__", ".venv"],
        suffixes: ["_files"]
    )

    public func ignores(name: String, isDirectory: Bool) -> Bool {
        names.contains(name) || (isDirectory && suffixes.contains { name.hasSuffix($0) })
    }

    /// `components` are the path components below a watched root. Everything but the last one is a directory.
    public func ignores(components: [String], lastIsDirectory: Bool) -> Bool {
        for (i, name) in components.enumerated() where ignores(name: name, isDirectory: i < components.count - 1 || lastIsDirectory) {
            return true
        }
        return false
    }
}
