import Foundation

/// A test launch that must not touch the user's real state (Debug builds only; the app ignores the variables in Release).
///
/// `MACDOWN2_DEFAULTS_SUITE=<name>` moves every preference read and write into that `UserDefaults` suite, so the real
/// domain's windows, frames and recents are neither restored nor changed. `MACDOWN2_ALLOWED_ROOT=<dir>` is the fuse:
/// a file outside that folder is refused. An isolated launch with no (usable) root refuses every file.
public struct IsolatedLaunch: Equatable, Sendable {
    public static let suiteVariable = "MACDOWN2_DEFAULTS_SUITE"
    public static let rootVariable = "MACDOWN2_ALLOWED_ROOT"

    public enum Failure: Error, Equatable {
        /// Empty, a path, or the app's own / the global domain: the one thing isolation must never fall back to.
        case unusableSuite(String)
    }

    public let suiteName: String
    /// nil = no usable root (unset, empty or relative): nothing may be opened.
    public let allowedRoot: URL?

    /// nil when the environment asks for no isolation. `reservedSuites` are the domains a suite must never be (the app's
    /// own bundle id, which is what `UserDefaults.standard` is).
    public init?(environment: [String: String], reservedSuites: Set<String>) throws {
        guard let suite = environment[Self.suiteVariable] else { return nil }
        let reserved = reservedSuites.union(["NSGlobalDomain", "Apple Global Domain"])
        guard !suite.isEmpty, !suite.contains("/"), !reserved.contains(suite) else { throw Failure.unusableSuite(suite) }
        suiteName = suite
        let root = environment[Self.rootVariable] ?? ""
        allowedRoot = root.hasPrefix("/") ? URL(filePath: root, directoryHint: .isDirectory) : nil
    }

    /// Whether `url` is the root or inside it, after symlinks (`/var` vs `/private/var`, a link pointing out) and `..`
    /// are resolved; whole path components, so `/tmp/ab` is not inside `/tmp/a`.
    // lazy: path compare is case-sensitive; the launcher copies files itself, so the spelling always matches
    public func allows(_ url: URL) -> Bool {
        guard let allowedRoot else { return false }
        let root = Self.components(allowedRoot)
        let path = Self.components(url)
        return path.count >= root.count && path.prefix(root.count).elementsEqual(root)
    }

    private static func components(_ url: URL) -> [String] { url.resolvingSymlinksInPath().standardizedFileURL.pathComponents }
}
