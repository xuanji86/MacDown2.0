import ExtensionAPI
import Foundation

/// A usable `quarto`: where it is, its version, and how it was found.
public struct QuartoLocation: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Settings ▸ Extensions ▸ Quarto ▸ Quarto path.
        case manual
        /// `command -v quarto` in the login shell's PATH.
        case loginPath
        /// One of `QuartoLocator.fallbackDirectories`.
        case fallbackDirectory
    }

    public var path: String
    public var version: String
    public var source: Source
}

public enum QuartoLookup: Sendable, Equatable {
    case found(QuartoLocation)
    /// Why there is no usable quarto, for the user.
    case notFound(String)
}

/// Finds `quarto` for the real render (PLAN 4.6.2): the manual path from the settings, else the first `quarto` on the login shell's
/// PATH, then the usual install directories; each candidate must answer `quarto --version` with 1.4 or later. Runs only when the user
/// switches to the real render or opens the extension's settings, never at launch.
enum QuartoLocator {
    static let minimumVersion: ToolVersion = [1, 4]
    /// Looked at after the login shell's PATH, in this order: the app's fallback PATH entries, with the Quarto installer's folder
    /// right after /usr/local/bin (whose `quarto` is usually a link into it).
    static let fallbackDirectories = LoginShellEnvironment.fallbackPathEntries.flatMap { $0 == "/usr/local/bin" ? [$0, "/Applications/quarto/bin"] : [$0] }

    /// `spawner` runs `quarto --version` (in the tool environment); `timeout` is per candidate (a cold Deno start takes ~0.5 s).
    static func locate(
        manualPath: String?, environment: ToolEnvironmentSnapshot, spawner: any ProcessSpawner,
        fallbackDirectories: [String] = fallbackDirectories, home: String = NSHomeDirectory(), timeout: Duration = .seconds(20)
    ) async -> QuartoLookup {
        if let manual = manualPath?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            let path = (manual as NSString).expandingTildeInPath
            guard ToolEnvironmentSnapshot.isTool(atPath: path) else { return .notFound(L10n.notExecutable(path)) }
            return await check(path, source: .manual, spawner: spawner, home: home, timeout: timeout)
        }
        var candidates: [(path: String, source: QuartoLocation.Source)] = []
        if let onPath = environment.which("quarto") { candidates.append((onPath, .loginPath)) }
        for directory in fallbackDirectories {
            let path = (LoginShellEnvironment.expandHome(directory, home: home) as NSString).appendingPathComponent("quarto")
            if ToolEnvironmentSnapshot.isTool(atPath: path) { candidates.append((path, .fallbackDirectory)) }
        }
        // /usr/local/bin/quarto is usually a link to /Applications/quarto/bin/quarto: ask each real file once.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert(URL(filePath: $0.path).resolvingSymlinksInPath().path).inserted }
        var firstProblem: String?
        for candidate in candidates {
            let lookup = await check(candidate.path, source: candidate.source, spawner: spawner, home: home, timeout: timeout)
            guard case .notFound(let reason) = lookup else { return lookup }
            firstProblem = firstProblem ?? reason
        }
        return .notFound(firstProblem ?? L10n.quartoNotFound)
    }

    /// `quarto --version` at `path`: found when it answers with a supported version, else why not.
    private static func check(_ path: String, source: QuartoLocation.Source, spawner: any ProcessSpawner, home: String, timeout: Duration) async -> QuartoLookup {
        let output: ProcessOutput
        do {
            output = try await withTimeout(timeout) { try await spawner.run(executable: path, arguments: ["--version"], directory: home) }
        } catch {
            return .notFound(L10n.versionFailed(path, error.localizedDescription))
        }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.status == 0, let version = parseVersion(text) else {
            return .notFound(L10n.versionFailed(path, "exit status \(output.status)"))
        }
        guard isSupported(version) else { return .notFound(L10n.tooOld(version.description, path)) }
        return .found(QuartoLocation(path: path, version: version.description, source: source))
    }

    /// "1.10.19" (what `quarto --version` prints, maybe after other lines) → [1, 10, 19]; nil when no line is a version.
    static func parseVersion(_ output: String) -> ToolVersion? {
        output.split(whereSeparator: \.isNewline).reversed().lazy.compactMap { ToolVersion($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    static func isSupported(_ version: ToolVersion) -> Bool { version.isAtLeast(minimumVersion) }
}
