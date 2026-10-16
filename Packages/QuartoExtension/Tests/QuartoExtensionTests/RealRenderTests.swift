import Darwin
import ExtensionAPI
import Foundation
import Testing
@testable import QuartoExtension

// PLAN 4.6.2 / 6.1: the real render. Fake `quarto` scripts stand in for the real one: what they print, how they die, which
// directory and environment they got. No test here needs Quarto to be installed.

/// A fresh directory for one test.
func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "md2-quarto-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An executable `/bin/sh` script `name` in `directory`. `$log` and `$port` hold the `--log` / `--port` arguments of a `preview` call.
@discardableResult
func fakeQuarto(in directory: URL, name: String = "quarto", version: String = "1.6.0", preview body: String) throws -> URL {
    let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo \(version); exit 0; fi
    log=""; port=""
    while [ $# -gt 0 ]; do
      case "$1" in --log) log="$2"; shift ;; --port) port="$2"; shift ;; esac
      shift
    done
    \(body)
    """
    let url = directory.appending(path: name)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Waits up to `seconds` for `condition`.
private func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func pids(in file: URL) -> [pid_t] {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
}

private let plainEnvironment = ["PATH": "/usr/bin:/bin"]

// MARK: Version and location

@Test func versionParsing() {
    #expect(QuartoLocator.parseVersion("1.10.19\n") == [1, 10, 19])
    #expect(QuartoLocator.parseVersion("WARNING: something\n1.4.550\n") == [1, 4, 550])
    #expect(QuartoLocator.parseVersion("99.9.9") == [99, 9, 9])
    #expect(QuartoLocator.parseVersion("quarto") == nil)
    #expect(QuartoLocator.parseVersion("") == nil)
    #expect(QuartoLocator.parseVersion("1") == nil)
    #expect(!QuartoLocator.isSupported([1, 3, 450]))
    #expect(QuartoLocator.isSupported([1, 4]))
    #expect(QuartoLocator.isSupported([1, 4, 0]))
    #expect(QuartoLocator.isSupported([1, 10, 19]))
    #expect(QuartoLocator.isSupported([2, 0]))
    #expect(!QuartoLocator.isSupported([0, 99]))
}

/// Counts `--version` runs per path, and runs them for real.
private final class RecordingSpawner: ProcessSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String] = []
    var paths: [String] { lock.withLock { runs } }
    func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        lock.withLock { runs.append(executable) }
        return try await SystemProcessSpawner(environment: plainEnvironment).run(executable: executable, arguments: arguments, directory: directory)
    }
}

@Test func locatorOrder_manualThenLoginPathThenFallbackDirectories() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let onPath = root.appending(path: "path"), first = root.appending(path: "fallback1"), second = root.appending(path: "fallback2"), manual = root.appending(path: "manual")
    for directory in [onPath, first, second, manual] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let environment = ToolEnvironmentSnapshot(environment: ["PATH": "/nowhere:\(onPath.path)"], source: .loginShell(path: "/bin/zsh"), seconds: 0)
    let fallbacks = [first.path, second.path]
    func locate(_ manualPath: String? = nil, spawner: any ProcessSpawner = RecordingSpawner()) async -> QuartoLookup {
        await QuartoLocator.locate(manualPath: manualPath, environment: environment, spawner: spawner, fallbackDirectories: fallbacks, home: root.path)
    }

    // Nothing anywhere.
    #expect(await locate() == .notFound(L10n.quartoNotFound))

    // Only in the second fallback directory.
    try fakeQuarto(in: second, version: "1.5.57", preview: "")
    #expect(await locate() == .found(QuartoLocation(path: second.appending(path: "quarto").path, version: "1.5.57", source: .fallbackDirectory)))

    // The first fallback directory comes before the second.
    try fakeQuarto(in: first, version: "1.6.1", preview: "")
    #expect(await locate() == .found(QuartoLocation(path: first.appending(path: "quarto").path, version: "1.6.1", source: .fallbackDirectory)))

    // The login shell's PATH comes before both.
    try fakeQuarto(in: onPath, version: "1.10.19", preview: "")
    #expect(await locate() == .found(QuartoLocation(path: onPath.appending(path: "quarto").path, version: "1.10.19", source: .loginPath)))

    // A manual path wins over everything.
    let mine = try fakeQuarto(in: manual, name: "my-quarto", version: "1.7.0", preview: "")
    #expect(await locate(mine.path) == .found(QuartoLocation(path: mine.path, version: "1.7.0", source: .manual)))
    // A manual path that is not a program is an error of its own, never silently replaced by another quarto.
    #expect(await locate(manual.appending(path: "missing").path) == .notFound(L10n.notExecutable(manual.appending(path: "missing").path)))
    // Blank = not set.
    #expect(await locate("  ") == .found(QuartoLocation(path: onPath.appending(path: "quarto").path, version: "1.10.19", source: .loginPath)))
}

@Test func locatorSkipsTooOldAndAsksEachRealFileOnce() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let onPath = root.appending(path: "path"), linked = root.appending(path: "linked"), fallback = root.appending(path: "fallback")
    for directory in [onPath, linked, fallback] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let old = try fakeQuarto(in: onPath, version: "1.3.450", preview: "")
    // /usr/local/bin/quarto -> /Applications/quarto/bin/quarto, in miniature: the same old quarto through a link.
    try FileManager.default.createSymbolicLink(at: linked.appending(path: "quarto"), withDestinationURL: old)
    try fakeQuarto(in: fallback, version: "1.4.0", preview: "")
    let environment = ToolEnvironmentSnapshot(environment: ["PATH": onPath.path], source: .loginShell(path: "/bin/zsh"), seconds: 0)
    let spawner = RecordingSpawner()
    let found = await QuartoLocator.locate(manualPath: nil, environment: environment, spawner: spawner, fallbackDirectories: [linked.path, fallback.path], home: root.path)
    #expect(found == .found(QuartoLocation(path: fallback.appending(path: "quarto").path, version: "1.4.0", source: .fallbackDirectory)))
    #expect(spawner.paths == [old.path, fallback.appending(path: "quarto").path])  // the link to the old one was not asked again

    // Only the old one: say so (not "not found").
    let onlyOld = await QuartoLocator.locate(manualPath: nil, environment: environment, spawner: RecordingSpawner(), fallbackDirectories: [], home: root.path)
    #expect(onlyOld == .notFound(L10n.tooOld("1.3.450", old.path)))
}

// MARK: Console and log

@Test func pageURLFromQuartosOutput() {
    // What Quarto 1.10 prints, colours included; it says "localhost" although it listens on 127.0.0.1.
    #expect(QuartoConsole.pageURL(in: QuartoConsole.clean("\u{1B}[32mBrowse at \u{1B}[39m\u{1B}[4m\u{1B}[32mhttp://localhost:4321/\u{1B}[39m\u{1B}[24m")) == URL(string: "http://127.0.0.1:4321/"))
    // The port is Quarto's choice, not ours.
    #expect(QuartoConsole.pageURL(in: "Browse at http://localhost:61234/") == URL(string: "http://127.0.0.1:61234/"))
    #expect(QuartoConsole.pageURL(in: "Listening on http://127.0.0.1:4321/") == URL(string: "http://127.0.0.1:4321/"))
    // A document in a project is served under its path.
    #expect(QuartoConsole.pageURL(in: "Browse at http://localhost:4200/notes/doc.html") == URL(string: "http://127.0.0.1:4200/notes/doc.html"))
    #expect(QuartoConsole.pageURL(in: "Browse at http://127.0.0.1:4200") == URL(string: "http://127.0.0.1:4200/"))
    // Never anything but a loopback http page.
    #expect(QuartoConsole.pageURL(in: "Browse at http://example.com:4321/") == nil)
    #expect(QuartoConsole.pageURL(in: "Browse at https://localhost:4321/") == nil)
    #expect(QuartoConsole.pageURL(in: "Browse at http://localhost/") == nil)
    #expect(QuartoConsole.pageURL(in: "Watching files for changes") == nil)
    #expect(QuartoConsole.pageURL(in: "echo Browse at http://localhost:1/") == nil)
}

@Test func consoleLinesAfterTheStart() {
    if case .rendered = QuartoConsole.event(for: "Output created: doc.html") {} else { Issue.record("Output created is a finished render") }
    #expect(QuartoConsole.event(for: "ERROR: Error in Python code") == .renderFailed)
    #expect(QuartoConsole.event(for: "pandoc ") == .rendering)
    #expect(QuartoConsole.event(for: "Starting python3 kernel...Done") == .rendering)
    #expect(QuartoConsole.event(for: "Watching files for changes") == nil)
    #expect(QuartoConsole.event(for: "   ") == nil)
}

@Test func logErrorEntries() {
    let log = """
    {"msg":"pandoc ","level":20,"levelName":"INFO","loggerName":"default"}

    {"msg":"\\u001b[31mERROR: boom\\u001b[39m\\n","level":40,"levelName":"ERROR","loggerName":"default"}
    not json
    {"msg":"fatal","level":50,"levelName":"CRITICAL"}
    {"msg":"careful","level":30,"levelName":"WARNING"}
    """
    #expect(QuartoLog.errors(inLog: Data(log.utf8)) == ["ERROR: boom", "fatal"])
}

@Test func commandLine() {
    let document = URL(filePath: "/tmp/a b/doc.qmd"), log = URL(filePath: "/tmp/quarto-x.log")
    #expect(QuartoPreviewProcess.arguments(document: document, port: 4321, logFile: log) == [
        "preview", "/tmp/a b/doc.qmd", "--no-browser", "--host", "127.0.0.1", "--port", "4321",
        "--render", "html", "--log", "/tmp/quarto-x.log", "--log-format", "json-stream",
    ])
    #expect(!QuartoPreviewProcess.arguments(document: document, port: nil, logFile: log).contains("--port"))
    let port = QuartoPreviewProcess.freePort()
    #expect(port.map { $0 > 0 && $0 < 65536 } == true)
}

// MARK: The process

/// A document in its own folder, and a fake quarto next to it.
private func setUp(_ body: String) throws -> (root: URL, document: URL, quarto: URL) {
    let root = try scratchDirectory()
    let folder = root.appending(path: "docs")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let document = folder.appending(path: "doc.qmd")
    try "# Hi\n".write(to: document, atomically: true, encoding: .utf8)
    let quarto = try fakeQuarto(in: root, preview: body)
    return (root, document, quarto)
}

@Test func startReadsTheURLRunsInTheDocumentFolderWithTheEnvironmentAndSIGTERMStopsTheGroup() async throws {
    // Prints the page on stderr (as Quarto does), records its folder, environment and pids, then waits with a child in its group.
    let (root, document, quarto) = try setUp("""
    pwd -P > "$(dirname "$0")/cwd"; echo "$MD2_MARKER" > "$(dirname "$0")/env"; echo "$port" > "$(dirname "$0")/port"
    echo '{"msg":"ERROR: from the log","level":40}' > "$log"
    sleep 1000 & echo "$$ $!" > "$(dirname "$0")/pids"
    printf '\\033[32mBrowse at \\033[39mhttp://localhost:%s/\\n' "$port" >&2
    wait
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment.merging(["MD2_MARKER": "login-env"]) { $1 })
    let url = try await process.start()
    let port = try String(contentsOf: root.appending(path: "port"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(url == URL(string: "http://127.0.0.1:\(port)/"))
    let folder = try #require(realpath(document.deletingLastPathComponent().path, nil))
    defer { free(folder) }
    #expect(try String(contentsOf: root.appending(path: "cwd"), encoding: .utf8).trimmingCharacters(in: .newlines) == String(cString: folder))
    #expect(try String(contentsOf: root.appending(path: "env"), encoding: .utf8) == "login-env\n")
    #expect(FileManager.default.fileExists(atPath: process.logFile.path))
    #expect(await process.logText() == "ERROR: from the log")

    let group = pids(in: root.appending(path: "pids"))
    #expect(group.count == 2 && group.allSatisfy(isAlive))
    let started = Date()
    await process.stop()
    #expect(Date().timeIntervalSince(started) < 2.5)  // SIGTERM did it, no SIGKILL wait
    #expect(await eventually { !group.contains(where: isAlive) })  // the script and its child: the whole group
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))  // the temp log is gone with the process
    #expect(await process.logText() == "ERROR: from the log")  // read before it was deleted
    await process.stop()  // idempotent
}

@Test func aGroupThatIgnoresSIGTERMIsKilledAfterThreeSeconds() async throws {
    let (root, document, quarto) = try setUp("""
    trap '' TERM
    sleep 1000 & echo "$$ $!" > "$(dirname "$0")/pids"
    echo "Browse at http://localhost:$port/" >&2
    wait
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    _ = try await process.start()
    let group = pids(in: root.appending(path: "pids"))
    #expect(group.count == 2)
    let started = Date()
    await process.stop()
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed >= 2.9 && elapsed < 5, "SIGKILL comes 3 s after SIGTERM (took \(elapsed) s)")
    #expect(await eventually { !group.contains(where: isAlive) })
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))
}

/// `quarto` is a bash script that dies of the SIGTERM at once while Deno, in the same group, still removes its temp files: the rest of
/// the group gets its grace too, it is not SIGKILLed the moment the script is gone.
@Test func theRestOfTheGroupMayFinishCleaningUpAfterTheScriptDies() async throws {
    let (root, document, quarto) = try setUp("""
    marker="$(dirname "$0")/cleaned"
    sh -c "trap 'sleep 0.5; touch \\"$marker\\"; exit 0' TERM; while :; do sleep 0.1; done" &
    echo "Browse at http://localhost:$port/" >&2
    wait
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    _ = try await process.start()
    try await Task.sleep(for: .milliseconds(200))
    await process.stop()
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "cleaned").path))
}

@Test func noPageWithinTheTimeoutIsAFailedStartAndStopsTheProcess() async throws {
    let (root, document, quarto) = try setUp("""
    echo "$$" > "$(dirname "$0")/pids"; echo "pandoc"; sleep 1000
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment, timeout: .milliseconds(800))
    await #expect(throws: QuartoPreviewProcess.StartError.timedOut) { try await process.start() }
    let group = pids(in: root.appending(path: "pids"))
    #expect(group.count == 1)
    #expect(await eventually { !group.contains(where: isAlive) })
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))
    #expect(await process.logText() == "pandoc")
}

@Test func exitingBeforeThePageIsAFailedStartWithItsCode() async throws {
    let (root, document, quarto) = try setUp("""
    echo "ERROR: YAML parse error" >&2; exit 3
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    await #expect(throws: QuartoPreviewProcess.StartError.exited(3)) { try await process.start() }
    #expect(await process.logText() == "ERROR: YAML parse error")
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))
}

@Test func aMissingQuartoIsALaunchFailure() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: root.appending(path: "nope").path, document: root.appending(path: "doc.qmd"), environment: plainEnvironment)
    do {
        _ = try await process.start()
        Issue.record("started a missing program")
    } catch let error as QuartoPreviewProcess.StartError {
        if case .launch = error {} else { Issue.record("expected a launch failure, got \(error)") }
    }
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))
}

@Test func rendersAfterTheStartAndACrashAreReported() async throws {
    let (root, document, quarto) = try setUp("""
    echo "Output created: doc.html"; echo "Watching files for changes"
    echo "Browse at http://localhost:$port/" >&2
    sleep 0.3; echo "pandoc "; echo "Output created: doc.html"
    sleep 0.3; echo "ERROR: Error in Python code" >&2
    sleep 0.3; exit 2
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    _ = try await process.start()
    var events: [QuartoPreviewProcess.Event] = []
    for await event in process.events {
        if case .rendered = event { events.append(.rendered(.distantPast)) } else { events.append(event) }
    }
    // The first .rendered is the start's own (the page is up).
    #expect(events == [.rendered(.distantPast), .rendering, .rendered(.distantPast), .renderFailed, .exited(2)])
    #expect(!FileManager.default.fileExists(atPath: process.logFile.path))
}

@Test func stopWhileStartingCancelsTheStart() async throws {
    let (root, document, quarto) = try setUp("sleep 1000")
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    let start = Task { try await process.start() }
    try await Task.sleep(for: .milliseconds(200))
    await process.stop()
    await #expect(throws: QuartoPreviewProcess.StartError.stopped) { try await start.value }
}

@Test func appQuitStopsEveryChild() async throws {
    let (root, document, quarto) = try setUp("""
    trap '' TERM
    echo "$$" > "$(dirname "$0")/pids"; echo "Browse at http://localhost:$port/" >&2; sleep 1000
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = QuartoPreviewProcess(quarto: quarto.path, document: document, environment: plainEnvironment)
    _ = try await process.start()
    let group = pids(in: root.appending(path: "pids"))
    // What `willTerminateNotification` runs (blocking): SIGTERM, a grace period, SIGKILL.
    await Task.detached { QuartoChild.stopAllForQuit(grace: 0.3) { group.contains($0) } }.value
    #expect(await eventually { !group.contains(where: isAlive) })
}

// MARK: Consent

/// Previewing a document of a Quarto project renders the whole project (other documents' code, the project's filters), so the question
/// says so, and is asked once per project even with "Ask before rendering" off.
@Test @MainActor func projectDocumentsAskAboutTheWholeProject() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "site"), chapter = project.appending(path: "chapters")
    try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
    try "project:\n  type: website\n".write(to: project.appending(path: "_quarto.yaml"), atomically: true, encoding: .utf8)
    let inside = chapter.appending(path: "one.qmd"), sibling = project.appending(path: "index.qmd"), outside = root.appending(path: "loose.qmd")
    #expect(QuartoRealRender.projectRoot(of: inside)?.path == project.standardizedFileURL.path)
    #expect(QuartoRealRender.projectRoot(of: outside) == nil)
    #expect(QuartoRealRender.projectRoot(of: URL(filePath: "/doc.qmd")) == nil)  // the walk ends at /

    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    defaults.set(false, forKey: "extension.quarto.askEveryTime")
    let mode = QuartoRealRender(settings: ExtensionSettingsStore(defaults: defaults, extension: "quarto"), toolEnvironment: LoginShellEnvironment())
    #expect(mode.confirmation(for: outside) == nil)  // asking turned off, no project
    let ask = try #require(mode.confirmation(for: inside))  // asking turned off, but a project is more than this document
    #expect(ask.message == L10n.confirmProjectMessage("one.qmd", project.standardizedFileURL.path))
    mode.confirmed(for: inside)
    #expect(mode.confirmation(for: sibling) == nil)  // that project is agreed to for this session

    mode.asksEveryTime = true
    #expect(mode.confirmation(for: sibling)?.message == L10n.confirmMessage)  // and with asking on, the per-document question again
    #expect(mode.confirmation(for: outside)?.message == L10n.confirmMessage)
}
