import Foundation

/// The environment external tools (quarto, qmd, python, R) should run in, and where it came from.
public struct ToolEnvironmentSnapshot: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from this login shell.
        case loginShell(path: String)
        /// The login shell could not be read (`reason`); the app's own environment plus the usual tool directories.
        case fallback(reason: String)
    }

    public var environment: [String: String]
    public var source: Source
    /// How long reading it took, in seconds.
    public var seconds: Double

    public init(environment: [String: String], source: Source, seconds: Double) {
        self.environment = environment
        self.source = source
        self.seconds = seconds
    }

    /// The `PATH` entries in order, empty ones dropped.
    public var path: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// First executable file called `name` on `PATH`; a `name` containing "/" is checked as it is. No shell is started.
    public func which(_ name: String) -> String? {
        let fm = FileManager.default
        func isTool(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && fm.isExecutableFile(atPath: path)
        }
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            return isTool(expanded) ? expanded : nil
        }
        return path.lazy.map { ($0 as NSString).appendingPathComponent(name) }.first(where: isTool)
    }
}

public enum ToolEnvironmentState: Sendable, Equatable {
    /// Nothing has asked for it yet.
    case notNeeded
    case loading
    case ready(ToolEnvironmentSnapshot)
}

/// What an extension gets from `ExtensionHost.toolEnvironment`. The first `snapshot()` is what does the work (PLAN 4.16);
/// nothing about obtaining a host or an extension being on triggers it.
public protocol ToolEnvironment: Sendable {
    func snapshot() async -> ToolEnvironmentSnapshot
}

extension ToolEnvironment {
    /// `ToolEnvironmentSnapshot.which` on the (first) snapshot.
    public func which(_ name: String) async -> String? { await snapshot().which(name) }
}

/// Reads the user's login-shell environment once, on first need, and keeps it (PLAN 4.16): a GUI app launched from the
/// Dock has only launchd's `/usr/bin:/bin:/usr/sbin:/sbin`, so quarto, qmd, conda and R would not be found.
///
/// Never runs at launch and never for core features: only a caller of `snapshot()` / `reread()` starts the shell, and
/// `ExtensionHost.toolEnvironment` plus the Settings "re-read" button are the only callers. Nothing is written to the
/// system (no `launchctl setenv`) and rc files are not parsed: the shell itself is asked.
public actor LoginShellEnvironment: ToolEnvironment {
    /// Appended to `PATH` when the shell could not be read.
    public static let fallbackPathEntries = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
    /// Variables describing the shell session rather than the user's setup; dropped (and `TERM*` by prefix).
    static let droppedKeys: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    private let spawner: any ProcessSpawner
    private let timeout: Duration
    private let processEnvironment: [String: String]
    private let home: String
    private var cached: ToolEnvironmentSnapshot?
    private var inflight: Task<ToolEnvironmentSnapshot, Never>?

    public init(
        spawner: any ProcessSpawner = SystemProcessSpawner(),
        timeout: Duration = .seconds(5),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) {
        self.spawner = spawner
        self.timeout = timeout
        self.processEnvironment = processEnvironment
        self.home = home
    }

    /// What has happened so far; never starts the shell (the Settings row reads this).
    public func state() -> ToolEnvironmentState {
        if let cached { return .ready(cached) }
        return inflight == nil ? .notNeeded : .loading
    }

    /// The cached environment; the first call (all concurrent callers share it) reads the login shell.
    public func snapshot() async -> ToolEnvironmentSnapshot {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        return await start().value
    }

    /// Reads the login shell again (the user changed their rc files). Joins a read that is already running.
    @discardableResult
    public func reread() async -> ToolEnvironmentSnapshot {
        if let inflight { return await inflight.value }
        cached = nil
        return await start().value
    }

    private func start() -> Task<ToolEnvironmentSnapshot, Never> {
        // Unstructured on purpose: one caller being cancelled must not cancel the read the others share.
        let task = Task {
            let snapshot = await self.capture()
            self.finish(snapshot)
            return snapshot
        }
        inflight = task
        return task
    }

    private func finish(_ snapshot: ToolEnvironmentSnapshot) {
        cached = snapshot
        inflight = nil
    }

    // MARK: Reading the shell

    private enum Outcome: Sendable {
        case output(ProcessOutput)
        case failed(String)
        case timedOut
    }

    private func capture() async -> ToolEnvironmentSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> Double {
            let d = start.duration(to: clock.now).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        func fallback(_ reason: String) -> ToolEnvironmentSnapshot {
            ToolEnvironmentSnapshot(environment: fallbackEnvironment(), source: .fallback(reason: reason), seconds: seconds())
        }

        let shell = processEnvironment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        // csh/tcsh take `-l` only as the sole argument, so `-l -c` is not available there.
        if shellName == "csh" || shellName == "tcsh" { return fallback("\(shellName) is not supported") }
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return fallback("\(shell) is not an executable shell") }

        let spawner = spawner, timeout = timeout, home = home
        let marker = "MD2ENV" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let arguments = Self.shellArguments(shellName: shellName, marker: marker)
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    return .output(try await spawner.run(executable: shell, arguments: arguments, directory: home))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return .failed("cancelled") }
                return .timedOut
            }
            let first = await group.next() ?? .failed("no result")
            group.cancelAll()  // kills the shell's process group when the timeout won
            return first
        }

        switch outcome {
        case .timedOut:
            return fallback("timed out after \(timeout.components.seconds) s")
        case .failed(let reason):
            return fallback(reason)
        case .output(let output):
            guard output.status == 0 else { return fallback("exit status \(output.status)") }
            guard let dump = Self.extract(output.stdout, marker: marker) else { return fallback("no environment in the shell's output") }
            let environment = Self.parse(dump)
            guard environment["PATH"] != nil else { return fallback("no PATH in the shell's environment") }
            return ToolEnvironmentSnapshot(environment: environment, source: .loginShell(path: shell), seconds: seconds())
        }
    }

    /// zsh and bash read `.zshrc` / `.bashrc` (where most people put PATH, conda, nvm) only when interactive, hence `-i -l`
    /// (what VS Code does). fish reads `config.fish` for every invocation and other shells get a plain login shell. An
    /// interactive rc prints banners and noise, so the dump is wrapped in `marker` and only what is between is parsed.
    /// stdin is /dev/null (the spawner), so nothing can wait for input.
    static func shellArguments(shellName: String, marker: String) -> [String] {
        let command = "printf %s \(marker); /usr/bin/env -0; printf %s \(marker)"
        return (shellName == "zsh" || shellName == "bash" ? ["-i", "-l", "-c"] : ["-l", "-c"]) + [command]
    }

    /// The bytes between the first two occurrences of `marker`; nil when it is not there twice.
    static func extract(_ data: Data, marker: String) -> Data? {
        let marker = Data(marker.utf8)
        guard let start = data.range(of: marker), let end = data.range(of: marker, in: start.upperBound..<data.endIndex) else { return nil }
        return data[start.upperBound..<end.lowerBound]
    }

    private func fallbackEnvironment() -> [String: String] {
        var environment = processEnvironment
        var entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in Self.fallbackPathEntries {
            let expanded = extra.hasPrefix("~/") ? home + extra.dropFirst(1) : extra
            if !entries.contains(expanded) { entries.append(expanded) }
        }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }

    /// `env -0` output → variables. Records are NUL-separated, so values may hold newlines; the key ends at the first `=`
    /// (values may hold more). A record without `=` or with a key containing whitespace/control characters is dropped.
    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for record in data.split(separator: 0) {
            let text = String(decoding: record, as: UTF8.self)
            guard let eq = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<eq])
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) else { continue }
            if droppedKeys.contains(key) || key.hasPrefix("TERM") { continue }
            result[key] = String(text[text.index(after: eq)...])
        }
        return result
    }
}
