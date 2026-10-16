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
    static let minimumVersion = [1, 4]
    /// Looked at after the login shell's PATH, in this order.
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/quarto/bin", "~/.local/bin"]

    /// `spawner` runs `quarto --version` (in the tool environment); `timeout` is per candidate (a cold Deno start takes ~0.5 s).
    static func locate(
        manualPath: String?, environment: ToolEnvironmentSnapshot, spawner: any ProcessSpawner,
        fallbackDirectories: [String] = fallbackDirectories, home: String = NSHomeDirectory(), timeout: Duration = .seconds(20)
    ) async -> QuartoLookup {
        if let manual = manualPath?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            let path = (manual as NSString).expandingTildeInPath
            guard isExecutableFile(path) else { return .notFound(L10n.notExecutable(path)) }
            switch await check(path, source: .manual, spawner: spawner, home: home, timeout: timeout) {
            case .success(let location): return .found(location)
            case .failure(let reason): return .notFound(reason.text)
            }
        }
        var candidates: [(path: String, source: QuartoLocation.Source)] = []
        if let onPath = environment.which("quarto") { candidates.append((onPath, .loginPath)) }
        for directory in fallbackDirectories {
            let expanded = directory.hasPrefix("~/") ? home + directory.dropFirst(1) : directory
            let path = (expanded as NSString).appendingPathComponent("quarto")
            if isExecutableFile(path) { candidates.append((path, .fallbackDirectory)) }
        }
        // /usr/local/bin/quarto is usually a link to /Applications/quarto/bin/quarto: ask each real file once.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert(URL(filePath: $0.path).resolvingSymlinksInPath().path).inserted }
        var firstProblem: String?
        for candidate in candidates {
            switch await check(candidate.path, source: candidate.source, spawner: spawner, home: home, timeout: timeout) {
            case .success(let location): return .found(location)
            case .failure(let reason): firstProblem = firstProblem ?? reason.text
            }
        }
        return .notFound(firstProblem ?? L10n.quartoNotFound)
    }

    struct Problem: Error { let text: String }

    private static func check(_ path: String, source: QuartoLocation.Source, spawner: any ProcessSpawner, home: String, timeout: Duration) async -> Result<QuartoLocation, Problem> {
        let output: ProcessOutput
        do {
            output = try await withTimeout(timeout) { try await spawner.run(executable: path, arguments: ["--version"], directory: home) }
        } catch {
            return .failure(Problem(text: L10n.versionFailed(path, error.localizedDescription)))
        }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.status == 0, let version = parseVersion(text) else {
            return .failure(Problem(text: L10n.versionFailed(path, "exit status \(output.status)")))
        }
        let shown = version.map(String.init).joined(separator: ".")
        guard isSupported(version) else { return .failure(Problem(text: L10n.tooOld(shown, path))) }
        return .success(QuartoLocation(path: path, version: shown, source: source))
    }

    /// "1.10.19" (what `quarto --version` prints, maybe after other lines) → [1, 10, 19]; nil when no line is a version.
    static func parseVersion(_ output: String) -> [Int]? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ".")
            guard parts.count >= 2 else { continue }
            let numbers = parts.compactMap { Int($0) }
            if numbers.count == parts.count { return numbers }
        }
        return nil
    }

    static func isSupported(_ version: [Int]) -> Bool {
        version.lexicographicallyPrecedes(minimumVersion) == false
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

struct TimedOut: Error, LocalizedError {
    var errorDescription: String? { "timed out" }
}

/// `work`, cancelled (the spawner then kills the process) when `timeout` passes first.
func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
