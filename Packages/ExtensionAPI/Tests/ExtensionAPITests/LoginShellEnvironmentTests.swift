import Foundation
import Testing
@testable import ExtensionAPI

/// A spawner that records what it was asked and answers from a script. Never starts a process.
final class CountingSpawner: ProcessSpawner, @unchecked Sendable {
    enum Behavior: Sendable {
        /// What `env -0` printed; the spawner wraps it in the marker the shell was asked to print, with `noise` around it
        /// (a banner an interactive rc printed).
        case output(Data, status: Int32 = 0, noise: String = "")
        /// Exactly these bytes (no marker).
        case raw(Data)
        /// Answers after a pause (so concurrent callers overlap).
        case delayed(Data, milliseconds: Int)
        /// Never answers until cancelled, like a login shell stuck in a blocking rc command.
        case hang
        case fail(String)
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var directory: String
    }

    private let lock = NSLock()
    private var behavior: Behavior
    private var recorded: [Call] = []
    private var cancels = 0

    init(_ behavior: Behavior = .fail("not scripted")) { self.behavior = behavior }

    func script(_ behavior: Behavior) { lock.withLock { self.behavior = behavior } }

    var calls: [Call] { lock.withLock { recorded } }
    var spawns: Int { calls.count }
    var cancellations: Int { lock.withLock { cancels } }

    /// `data` between two copies of the marker found in the command the shell was asked to run.
    static func wrap(_ data: Data, noise: String, arguments: [String]) -> Data {
        let last = arguments.last ?? ""
        let marker = last.range(of: "MD2ENV[0-9A-F]{32}", options: .regularExpression).map { String(last[$0]) } ?? ""
        return Data(noise.utf8) + Data(marker.utf8) + data + Data(marker.utf8) + Data(noise.utf8)
    }

    func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        let behavior = lock.withLock {
            recorded.append(Call(executable: executable, arguments: arguments, directory: directory))
            return self.behavior
        }
        do {
            switch behavior {
            case .output(let data, let status, let noise):
                return ProcessOutput(stdout: Self.wrap(data, noise: noise, arguments: arguments), status: status)
            case .raw(let data): return ProcessOutput(stdout: data, status: 0)
            case .delayed(let data, let ms):
                try await Task.sleep(for: .milliseconds(ms))
                return ProcessOutput(stdout: Self.wrap(data, noise: "", arguments: arguments), status: 0)
            case .hang:
                try await Task.sleep(for: .seconds(120))
                return ProcessOutput(stdout: Data(), status: 0)
            case .fail(let message): throw Failure(message: message)
            }
        } catch is CancellationError {
            lock.withLock { cancels += 1 }
            throw CancellationError()
        }
    }
}

/// `env -0` output for `pairs` (values may hold anything but NUL).
private func envOutput(_ pairs: [(String, String)]) -> Data {
    Data(pairs.map { "\($0.0)=\($0.1)\0" }.joined().utf8)
}

private let goodOutput = envOutput([
    ("PATH", "/opt/homebrew/bin:/usr/bin:/bin"), ("HOME", "/Users/test"), ("QUARTO_PYTHON", "/opt/py/bin/python"),
    ("_", "/usr/bin/env"), ("SHLVL", "1"), ("PWD", "/Users/test"), ("OLDPWD", "/"), ("TERM", "xterm"), ("TERM_PROGRAM", "x"),
])

/// A directory that is deleted when the test ends; `tool(named:)` makes an executable file there.
private final class Sandbox {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("login-shell-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    @discardableResult
    func file(_ name: String, executable: Bool) throws -> String {
        let path = url.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        return path
    }
}

private func makeEnvironment(
    _ spawner: CountingSpawner, shell: String? = "/bin/sh", timeout: Duration = .seconds(5),
    path: String? = "/usr/bin:/bin", home: String = "/Users/test"
) -> LoginShellEnvironment {
    var process = ["USER": "test"]
    if let shell { process["SHELL"] = shell }
    if let path { process["PATH"] = path }
    return LoginShellEnvironment(spawner: spawner, timeout: timeout, processEnvironment: process, home: home)
}

// MARK: Parsing

@Test func parseKeepsNewlinesEqualsSignsAndEmptyValues() {
    let data = envOutput([("MULTI", "line1\nline2\n"), ("EQ", "a=b=c"), ("EMPTY", ""), ("PATH", "/bin"), ("UNICODE", "héllo 世界")])
    #expect(LoginShellEnvironment.parse(data) == [
        "MULTI": "line1\nline2\n", "EQ": "a=b=c", "EMPTY": "", "PATH": "/bin", "UNICODE": "héllo 世界",
    ])
}

@Test func parseDropsShellSessionVariables() {
    let parsed = LoginShellEnvironment.parse(goodOutput)
    #expect(Set(parsed.keys) == ["PATH", "HOME", "QUARTO_PYTHON"])
}

@Test func parseToleratesNoTrailingNulStrayRecordsAndJunk() {
    #expect(LoginShellEnvironment.parse(Data("A=1\0B=2".utf8)) == ["A": "1", "B": "2"])  // no trailing NUL
    #expect(LoginShellEnvironment.parse(Data("A=1\0\0\0B=2\0".utf8)) == ["A": "1", "B": "2"])  // empty records
    #expect(LoginShellEnvironment.parse(Data("no equals here\0A=1\0=novalue-key\0".utf8)) == ["A": "1"])
    // text an rc file printed ahead of the first variable glues onto its record; the record is dropped, the rest survive
    #expect(LoginShellEnvironment.parse(Data("welcome back\nA=1\0B=2\0".utf8)) == ["B": "2"])
    #expect(LoginShellEnvironment.parse(Data()).isEmpty)
}

// MARK: Reading the shell

@Test func readsTheLoginShellOnceWithTheSpecifiedCommand() async {
    let spawner = CountingSpawner(.output(goodOutput))
    let env = makeEnvironment(spawner, home: "/Users/test")
    let snapshot = await env.snapshot()
    #expect(spawner.spawns == 1)
    let call = spawner.calls[0]
    #expect(call.executable == "/bin/sh" && call.directory == "/Users/test")
    #expect(call.arguments.dropLast() == ["-l", "-c"])  // plain login shell for anything but zsh and bash
    #expect(call.arguments.last?.contains("/usr/bin/env -0") == true)
    #expect(snapshot.source == .loginShell(path: "/bin/sh"))
    #expect(snapshot.environment["QUARTO_PYTHON"] == "/opt/py/bin/python")
    #expect(snapshot.environment["SHLVL"] == nil && snapshot.environment["TERM"] == nil && snapshot.environment["_"] == nil)
    #expect(snapshot.path == ["/opt/homebrew/bin", "/usr/bin", "/bin"])
    #expect(snapshot.seconds >= 0)
}

@Test func fishGetsTheSameCommand() async throws {
    let sandbox = try Sandbox()
    let fish = try sandbox.file("fish", executable: true)
    let spawner = CountingSpawner(.output(goodOutput))
    let snapshot = await makeEnvironment(spawner, shell: fish).snapshot()
    #expect(spawner.calls.first?.arguments.dropLast() == ["-l", "-c"])  // fish reads config.fish for every invocation
    #expect(snapshot.source == .loginShell(path: fish))
}

@Test func zshAndBashAreInteractiveLoginShellsSoTheirRcFilesAreRead() async throws {
    let sandbox = try Sandbox()
    for name in ["zsh", "bash"] {
        let spawner = CountingSpawner(.output(goodOutput))
        _ = await makeEnvironment(spawner, shell: try sandbox.file(name, executable: true)).snapshot()
        #expect(spawner.calls.first?.arguments.dropLast() == ["-i", "-l", "-c"])
    }
}

@Test func theDumpIsReadFromBetweenTheMarkersWhateverTheRcFilesPrint() async {
    let noise = "Welcome to my shell!\nloading nvm...\n"
    let snapshot = await makeEnvironment(CountingSpawner(.output(goodOutput, noise: noise))).snapshot()
    #expect(snapshot.source == .loginShell(path: "/bin/sh"))
    #expect(Set(snapshot.environment.keys) == ["PATH", "HOME", "QUARTO_PYTHON"])  // nothing swallowed, nothing added
    // no markers (the shell never reached the command) -> fallback
    guard case .fallback = await makeEnvironment(CountingSpawner(.raw(goodOutput))).snapshot().source else { Issue.record("expected a fallback"); return }
}

@Test func extractNeedsTheMarkerTwice() {
    #expect(LoginShellEnvironment.extract(Data("noiseMARKabcMARKtail".utf8), marker: "MARK") == Data("abc".utf8))
    #expect(LoginShellEnvironment.extract(Data("noiseMARKabc".utf8), marker: "MARK") == nil)
    #expect(LoginShellEnvironment.extract(Data("abc".utf8), marker: "MARK") == nil)
}

@Test func cshAndTcshFallBackWithoutSpawning() async throws {
    let sandbox = try Sandbox()
    for name in ["csh", "tcsh"] {
        let spawner = CountingSpawner(.output(goodOutput))
        let snapshot = await makeEnvironment(spawner, shell: try sandbox.file(name, executable: true)).snapshot()
        #expect(spawner.spawns == 0)
        guard case .fallback(let reason) = snapshot.source else { Issue.record("\(name) should fall back"); continue }
        #expect(reason.contains(name))
    }
}

@Test func missingSHELLDefaultsToZsh() async {
    let spawner = CountingSpawner(.output(goodOutput))
    _ = await makeEnvironment(spawner, shell: nil).snapshot()
    #expect(spawner.calls.first?.executable == "/bin/zsh")
}

// MARK: Fallback

@Test func timeoutKillsTheSpawnAndFallsBack() async {
    let spawner = CountingSpawner(.hang)
    let env = makeEnvironment(spawner, timeout: .milliseconds(150), path: "/usr/bin:/bin", home: "/Users/test")
    let started = ContinuousClock.now
    let snapshot = await env.snapshot()
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(spawner.spawns == 1)
    #expect(spawner.cancellations == 1)  // the spawner is cancelled, which is what kills the process group
    guard case .fallback(let reason) = snapshot.source else { Issue.record("expected a fallback"); return }
    #expect(reason.contains("timed out"))
    #expect(snapshot.path == ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/test/.local/bin"])
    #expect(snapshot.environment["USER"] == "test")  // the app's own environment is kept
    #expect(await env.state() == .ready(snapshot))
}

@Test func fallbackAddsEachExtraDirectoryOnlyOnce() async {
    let env = makeEnvironment(CountingSpawner(.fail("boom")), path: "/opt/homebrew/bin:/usr/bin", home: "/Users/test")
    #expect(await env.snapshot().path == ["/opt/homebrew/bin", "/usr/bin", "/usr/local/bin", "/Users/test/.local/bin"])
    let noPath = makeEnvironment(CountingSpawner(.fail("boom")), path: nil, home: "/h")
    #expect(await noPath.snapshot().path == ["/opt/homebrew/bin", "/usr/local/bin", "/h/.local/bin"])
}

@Test func failuresFallBackAndSayWhy() async throws {
    func reason(_ spawner: CountingSpawner, shell: String? = "/bin/sh") async -> String? {
        guard case .fallback(let reason) = await makeEnvironment(spawner, shell: shell).snapshot().source else { return nil }
        return reason
    }
    #expect(await reason(CountingSpawner(.fail("could not launch"))) == "could not launch")
    #expect(await reason(CountingSpawner(.output(goodOutput, status: 3))) == "exit status 3")
    #expect(await reason(CountingSpawner(.output(Data()))) != nil)  // nothing printed
    #expect(await reason(CountingSpawner(.output(envOutput([("HOME", "/x")])))) != nil)  // no PATH
    let sandbox = try Sandbox()
    let spawner = CountingSpawner(.output(goodOutput))
    #expect(await reason(spawner, shell: try sandbox.file("not-executable", executable: false)) != nil)
    #expect(await reason(spawner, shell: "/definitely/not/a/shell") != nil)
    #expect(await reason(spawner, shell: "zsh") != nil)  // must be an absolute path
    #expect(spawner.spawns == 0)
}

// MARK: Cache and state

@Test func twoConcurrentCallersShareOneSpawnAndLaterCallersUseTheCache() async {
    let spawner = CountingSpawner(.delayed(goodOutput, milliseconds: 150))
    let env = makeEnvironment(spawner)
    async let a = env.snapshot()
    async let b = env.snapshot()
    let (first, second) = await (a, b)
    #expect(first == second)
    #expect(spawner.spawns == 1)
    _ = await env.snapshot()
    _ = await env.which("sh")
    #expect(spawner.spawns == 1)
}

@Test func aCancelledCallerDoesNotPoisonTheSharedRead() async {
    let spawner = CountingSpawner(.delayed(goodOutput, milliseconds: 150))
    let env = makeEnvironment(spawner)
    let impatient = Task { await env.snapshot() }
    impatient.cancel()
    _ = await impatient.value
    let snapshot = await env.snapshot()
    #expect(snapshot.source == .loginShell(path: "/bin/sh"))
    #expect(spawner.spawns == 1)
}

@Test func stateNeverStartsTheShell() async {
    let spawner = CountingSpawner(.output(goodOutput))
    let env = makeEnvironment(spawner)
    for _ in 0..<3 { #expect(await env.state() == .notNeeded) }
    #expect(spawner.spawns == 0)
}

@Test func stateShowsLoadingThenReady() async throws {
    let env = makeEnvironment(CountingSpawner(.delayed(goodOutput, milliseconds: 300)))
    let reader = Task { await env.snapshot() }
    var sawLoading = false
    for _ in 0..<100 where !sawLoading {
        sawLoading = await env.state() == .loading
        if !sawLoading { try await Task.sleep(for: .milliseconds(5)) }
    }
    #expect(sawLoading)
    let snapshot = await reader.value
    #expect(await env.state() == .ready(snapshot))
}

@Test func rereadReadsAgainAndJoinsARunningRead() async {
    let spawner = CountingSpawner(.delayed(goodOutput, milliseconds: 100))
    let env = makeEnvironment(spawner)
    _ = await env.snapshot()
    #expect(spawner.spawns == 1)
    async let a = env.reread()
    async let b = env.reread()  // while the first re-read runs: joins it
    _ = await (a, b)
    #expect(spawner.spawns == 2)
}

// MARK: which

@Test func whichSearchesPathWithoutAnotherSpawn() async throws {
    let sandbox = try Sandbox()
    let tool = try sandbox.file("quarto", executable: true)
    try sandbox.file("plain", executable: false)
    try FileManager.default.createDirectory(at: sandbox.url.appendingPathComponent("adir"), withIntermediateDirectories: false)
    let other = try Sandbox()
    let shadowed = try other.file("quarto", executable: true)

    let output = envOutput([("PATH", "\(sandbox.url.path)::\(other.url.path)")])
    let spawner = CountingSpawner(.output(output))
    let env = makeEnvironment(spawner)
    #expect(await env.which("quarto") == tool)  // first PATH entry wins
    #expect(await env.which("plain") == nil)  // not executable
    #expect(await env.which("adir") == nil)  // a directory
    #expect(await env.which("nonexistent-tool") == nil)
    #expect(await env.which("") == nil)
    #expect(await env.which(shadowed) == shadowed)  // a path is checked as it is
    #expect(await env.which("/no/such/quarto") == nil)
    #expect(spawner.spawns == 1)  // the one environment read, no shell per lookup
}

private struct FixedEnvironment: ToolEnvironment {
    let snapshotValue: ToolEnvironmentSnapshot
    func snapshot() async -> ToolEnvironmentSnapshot { snapshotValue }
}

@Test func anyToolEnvironmentGetsWhichForFree() async throws {
    let sandbox = try Sandbox()
    let tool = try sandbox.file("qmd", executable: true)
    let stub = FixedEnvironment(snapshotValue: .init(environment: ["PATH": sandbox.url.path], source: .fallback(reason: "stub"), seconds: 0))
    #expect(await stub.which("qmd") == tool)
}

// MARK: The real thing

/// `SystemProcessSpawner` runs actual processes, but only `/bin/sh` one-liners: nothing here reads the user's shell setup.
@Test func systemSpawnerCapturesStdoutStatusAndRunsInTheDirectoryWithStdinClosed() async throws {
    let sandbox = try Sandbox()
    let spawner = SystemProcessSpawner()
    let out = try await spawner.run(executable: "/bin/sh", arguments: ["-c", #"printf 'A=1\0B=x\ny\0'"#], directory: sandbox.url.path)
    #expect(out.status == 0 && LoginShellEnvironment.parse(out.stdout) == ["A": "1", "B": "x\ny"])

    let cwd = try await spawner.run(executable: "/bin/sh", arguments: ["-c", "pwd -P"], directory: sandbox.url.path)
    #expect(String(decoding: cwd.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == String(cString: realpath(sandbox.url.path, nil)))

    let stdin = try await spawner.run(executable: "/bin/sh", arguments: ["-c", "cat; echo done"], directory: sandbox.url.path)
    #expect(String(decoding: stdin.stdout, as: UTF8.self) == "done\n")  // cat saw EOF at once

    let failed = try await spawner.run(executable: "/bin/sh", arguments: ["-c", "exit 7"], directory: sandbox.url.path)
    #expect(failed.status == 7)
    await #expect(throws: ProcessSpawnError.self) { try await spawner.run(executable: "/no/such/binary", arguments: [], directory: sandbox.url.path) }
}

@Test func cancellingTheSystemSpawnerKillsTheWholeProcessGroup() async throws {
    let sandbox = try Sandbox()
    let pidFile = sandbox.url.appendingPathComponent("grandchild.pid").path
    let task = Task {
        try await SystemProcessSpawner().run(executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $! > '\(pidFile)'; wait"], directory: sandbox.url.path)
    }
    var grandchild: pid_t = 0
    for _ in 0..<400 where grandchild == 0 {  // up to 4 s for the shell to record the pid of its child
        if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { grandchild = pid }
        else { try await Task.sleep(for: .milliseconds(10)) }
    }
    try #require(grandchild > 0)
    #expect(kill(grandchild, 0) == 0)  // alive

    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    var dead = false
    for _ in 0..<400 where !dead {
        dead = kill(grandchild, 0) != 0 && errno == ESRCH
        if !dead { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(dead, "the sleep started by the shell outlived the cancelled spawn")
}

@Test func timeoutThroughTheSystemSpawnerReturnsPromptly() async throws {
    let sandbox = try Sandbox()
    let sh = try sandbox.file("slow-shell", executable: true)
    // A "login shell" that ignores its arguments and blocks, like an rc file waiting on input.
    try "#!/bin/sh\nsleep 60\n".write(toFile: sh, atomically: true, encoding: .utf8)
    let env = LoginShellEnvironment(spawner: SystemProcessSpawner(), timeout: .milliseconds(300), processEnvironment: ["SHELL": sh, "PATH": "/usr/bin:/bin"], home: sandbox.url.path)
    let started = ContinuousClock.now
    let snapshot = await env.snapshot()
    #expect(started.duration(to: .now) < .seconds(5))
    guard case .fallback(let reason) = snapshot.source else { Issue.record("expected a fallback"); return }
    #expect(reason.contains("timed out"))
}

/// The real /bin/zsh and /bin/bash, but with HOME / ZDOTDIR pointing at a temp directory: they never see the user's rc
/// files. Proves the interactive flags: a variable exported from `.zshrc` (not `.zprofile`) must arrive, and the noise the
/// rc prints must not.
@Test func realZshReadsZshrcAndIgnoresItsNoise() async throws {
    let sandbox = try Sandbox()
    try "echo banner-on-stdout\necho banner-on-stderr >&2\nexport MD2_FROM_ZSHRC=yes\nexport PATH=\"/md2/from/zshrc:$PATH\"\n"
        .write(to: sandbox.url.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let home = sandbox.url.path
    let spawner = SystemProcessSpawner(environment: ["HOME": home, "ZDOTDIR": home, "PATH": "/usr/bin:/bin", "USER": "test"])
    let env = LoginShellEnvironment(spawner: spawner, timeout: .seconds(10), processEnvironment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"], home: home)
    let snapshot = await env.snapshot()
    #expect(snapshot.source == .loginShell(path: "/bin/zsh"))
    #expect(snapshot.environment["MD2_FROM_ZSHRC"] == "yes")
    #expect(snapshot.path.first == "/md2/from/zshrc")
    #expect(!snapshot.environment.keys.contains { $0.contains("banner") })
}

@Test func realBashReadsItsLoginProfile() async throws {
    let sandbox = try Sandbox()
    try "echo banner\nexport MD2_FROM_BASH=yes\n".write(to: sandbox.url.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
    let home = sandbox.url.path
    let spawner = SystemProcessSpawner(environment: ["HOME": home, "PATH": "/usr/bin:/bin", "USER": "test"])
    let env = LoginShellEnvironment(spawner: spawner, timeout: .seconds(10), processEnvironment: ["SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"], home: home)
    let snapshot = await env.snapshot()
    #expect(snapshot.source == .loginShell(path: "/bin/bash"))
    #expect(snapshot.environment["MD2_FROM_BASH"] == "yes")
}

/// A descendant that called setsid() (here via perl) and keeps stdout open is out of reach of `kill(-pgid)`; the read must
/// not wait for it.
@Test func aSetsidDescendantHoldingStdoutDoesNotHoldUpACancelOrAnExit() async throws {
    let sandbox = try Sandbox()
    let sleeper = "perl -MPOSIX -e 'POSIX::setsid(); sleep 4'"
    // cancel: the spawner returns about when asked, not when the sleeper lets go of the pipe
    let directory = sandbox.url.path
    let task = Task { try await SystemProcessSpawner().run(executable: "/bin/sh", arguments: ["-c", "\(sleeper) & sleep 60"], directory: directory) }
    try await Task.sleep(for: .milliseconds(300))
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(started.duration(to: .now) < .seconds(1.5))

    // exit: the shell finishes at once while the sleeper still holds stdout; what it printed comes back right away
    let t0 = ContinuousClock.now
    let out = try await SystemProcessSpawner().run(executable: "/bin/sh", arguments: ["-c", "\(sleeper) & echo done"], directory: sandbox.url.path)
    #expect(String(decoding: out.stdout, as: UTF8.self) == "done\n" && out.status == 0)
    #expect(t0.duration(to: .now) < .seconds(2.5))

    // and through LoginShellEnvironment: the timeout bounds the whole read
    let shell = try sandbox.file("slow-shell", executable: true)
    try "#!/bin/sh\n\(sleeper) &\nsleep 60\n".write(toFile: shell, atomically: true, encoding: .utf8)
    let env = LoginShellEnvironment(spawner: SystemProcessSpawner(), timeout: .milliseconds(300), processEnvironment: ["SHELL": shell, "PATH": "/usr/bin:/bin"], home: sandbox.url.path)
    let t1 = ContinuousClock.now
    let snapshot = await env.snapshot()
    #expect(t1.duration(to: .now) < .seconds(1.5))
    guard case .fallback(let reason) = snapshot.source else { Issue.record("expected a fallback"); return }
    #expect(reason.contains("timed out"))
}

/// Opt-in (`MD2_LOGIN_SHELL=1`): runs the real login shell of whoever runs the tests. Asserts structure only and never
/// prints a value (an environment can hold tokens).
@Test(.enabled(if: ProcessInfo.processInfo.environment["MD2_LOGIN_SHELL"] == "1", "set MD2_LOGIN_SHELL=1"))
func realLoginShellYieldsAUsablePath() async {
    let snapshot = await LoginShellEnvironment().snapshot()
    if case .fallback(let reason) = snapshot.source { Issue.record("the real login shell could not be read: \(reason)") }
    #expect(snapshot.path.contains("/usr/bin"))
    #expect(snapshot.path.count > 4)  // launchd's default is 4
    #expect(snapshot.environment["HOME"] != nil)
    #expect(snapshot.environment["SHLVL"] == nil && snapshot.environment["_"] == nil && snapshot.environment["OLDPWD"] == nil)
    #expect(!snapshot.environment.keys.contains { $0.hasPrefix("TERM") })
    #expect(await LoginShellEnvironment().which("sh") != nil)
}
