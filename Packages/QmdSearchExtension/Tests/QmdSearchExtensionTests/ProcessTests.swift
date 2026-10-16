import Darwin
import ExtensionAPI
import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

// Real processes: a stand-in qmd script for switching the extension off mid-search, and the real qmd (when installed)
// against a throwaway index.

private func processExists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

@MainActor private final class ScriptHost: ExtensionHost {
    let settings = ExtensionSettingsStore(defaults: UserDefaults(suiteName: "qmd-test.\(UUID().uuidString)")!, extension: QmdSearchExtension.id)
    let toolEnvironment: any ToolEnvironment
    var providers: [any SearchProvider] = []
    init(environment: any ToolEnvironment) { toolEnvironment = environment }
    func register(flavor: any DocumentFlavor) {}
    func register(searchProvider: any SearchProvider) { providers.append(searchProvider) }
}

struct ProcessTests {
    /// PLAN 6.1 "switched off while running": a search whose qmd never answers is killed within 3 s of `deactivate`.
    @Test @MainActor func deactivateKillsARunningQmdWithin3Seconds() async throws {
        let workspace = try temporaryFolder()
        let pidFile = workspace.deletingLastPathComponent().appending(path: "search.pid").path
        // Answers like qmd until asked to search, then records its pid and hangs.
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo "qmd 2.8.3 (stand-in)" ;;
          collection)
            case "$2" in
              list) printf 'Collections (1):\\n\\nmine (qmd://mine/)\\n  Pattern:  **/*.md\\n' ;;
              show) printf 'Collection: mine\\n  Path:     %s\\n  Pattern:  **/*.md\\n  Include:  yes (default)\\n' "$MD2_TEST_ROOT" ;;
            esac ;;
          search) echo $$ > "$MD2_TEST_PIDFILE"; exec /bin/sleep 30 ;;
        esac
        exit 0
        """
        let environment = try FakeEnvironment(extra: ["MD2_TEST_ROOT": realPath(workspace.path), "MD2_TEST_PIDFILE": pidFile], qmdScript: script)
        let ext = QmdSearchExtension()
        let host = ScriptHost(environment: environment)
        await ext.activate(host: host)
        let provider = try #require(host.providers.first)

        let search = Task { try await collect(provider.search(SearchQuery(text: "x"), in: workspace)) }
        var pid: pid_t = 0
        for _ in 0..<200 where pid == 0 {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        }
        try #require(pid > 0, "the stand-in qmd never started searching")
        #expect(processExists(pid))

        let start = ContinuousClock.now
        await ext.deactivate()
        while processExists(pid), ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!processExists(pid), "qmd still running 3 s after deactivate")
        let hits = try await search.value  // the stream ends quietly
        #expect(hits.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(ext.settingsPane() == nil)
    }

    /// A stand-in qmd whose `embed` starts a child (another process in its group, as Node's workers are) and hangs; both pids
    /// are written next to the workspace.
    private static func hangingEmbed(_ workspace: URL) throws -> (FakeEnvironment, pids: String) {
        let pids = workspace.deletingLastPathComponent().appending(path: "embed.pids").path
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo "qmd 2.8.3 (stand-in)" ;;
          collection)
            case "$2" in
              list) printf 'Collections (1):\\n\\nmine (qmd://mine/)\\n  Pattern:  **/*.md\\n  Files:    3\\n' ;;
              show) printf 'Collection: mine\\n  Path:     %s\\n  Pattern:  **/*.md\\n  Include:  yes (default)\\n' "$MD2_TEST_ROOT" ;;
            esac ;;
          embed) /bin/sleep 60 & echo "$$ $!" > "$MD2_TEST_PIDS"; wait ;;
          update) ;;
          *) echo '[]' ;;
        esac
        exit 0
        """
        return (try FakeEnvironment(extra: ["MD2_TEST_ROOT": realPath(workspace.path), "MD2_TEST_PIDS": pids], qmdScript: script), pids)
    }

    private static func waitForPids(_ path: String) async throws -> [pid_t] {
        for _ in 0..<200 {
            let pids = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            if pids.count == 2 { return pids }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CancellationError()
    }

    private static func gone(_ pids: [pid_t], within limit: Duration) async throws -> Bool {
        let start = ContinuousClock.now
        while pids.contains(where: processExists), ContinuousClock.now - start < limit { try await Task.sleep(for: .milliseconds(20)) }
        return !pids.contains(where: processExists)
    }

    /// The search panel's Cancel: the setup's qmd and everything in its process group are gone within 3 s.
    @Test func cancellingTheSemanticSetupKillsItsProcessGroupWithin3Seconds() async throws {
        let workspace = try temporaryFolder()
        let (environment, pidFile) = try Self.hangingEmbed(workspace)
        let provider = QmdSearchProvider(dependencies: QmdEngine.Dependencies(
            environment: environment, options: { QmdOptions(semantic: true) }, consent: { _ in .register }, decline: { _ in },
            watchFolders: false, setupPollInterval: .milliseconds(20)), semantic: true)
        #expect(try await provider.prepare(workspace: workspace) == .ready)
        let pids = try await Self.waitForPids(pidFile)
        #expect(pids.allSatisfy(processExists))
        #expect(await MainActor.run { provider.semanticSetup(for: workspace) } != .ready)

        await MainActor.run { provider.cancelSemanticSetup(for: workspace) }
        #expect(try await Self.gone(pids, within: .seconds(3)), "the setup's qmd still runs 3 s after Cancel")
        let stopped = SemanticSetup.failed(L10n.setupStopped)
        #expect(await eventually({ await MainActor.run { provider.semanticSetup(for: workspace) } }, { $0 == stopped }) == stopped)
    }

    /// Quitting the app and switching the extension off both stop a running setup.
    @Test @MainActor func quittingOrSwitchingOffKillsARunningSetup() async throws {
        for quit in [true, false] {
            let workspace = try temporaryFolder()
            let (environment, pidFile) = try Self.hangingEmbed(workspace)
            let ext = QmdSearchExtension()
            let host = ScriptHost(environment: environment)
            host.settings.set(true, for: QmdSettings.Key.semantic)
            await ext.activate(host: host)
            let provider = try #require(host.providers.first)
            #expect(try await provider.prepare(workspace: workspace) == .ready)
            let pids = try await Self.waitForPids(pidFile)

            if quit {
                ext.terminate()  // synchronous: the kill is sent before it returns
                #expect(try await Self.gone(pids, within: .seconds(1)), "the setup's qmd outlived the app's quit")
                await ext.deactivate()
            } else {
                await ext.deactivate()
                #expect(try await Self.gone(pids, within: .seconds(3)), "the setup's qmd still runs 3 s after switching off")
            }
        }
    }

    @Test func aSearchThatTakesTooLongIsKilledAtTheTimeout() async throws {
        let environment = try FakeEnvironment()
        let runner = QmdRunner(executable: "/bin/sleep", environment: await environment.snapshot().environment, makeSpawner: { SystemProcessSpawner(environment: $0) })
        let start = ContinuousClock.now
        await #expect(throws: QmdError.timedOut(seconds: 0)) { _ = try await runner.run(["30"], timeout: .milliseconds(300)) }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func stderrIsKeptAndExitStatusReported() async throws {
        let runner = QmdRunner(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], makeSpawner: { SystemProcessSpawner(environment: $0) })
        let ok = try await runner.run(["-c", "echo out; echo warn >&2"], timeout: .seconds(5))
        #expect(String(decoding: ok.stdout, as: UTF8.self) == "out\n" && ok.stderr == "warn")
        await #expect(throws: QmdError.failed(status: 3, message: "Error: boom")) {
            _ = try await runner.run(["-c", "echo 'Error: boom' >&2; exit 3"], timeout: .seconds(5))
        }
        let quoted = try await runner.run(["-c", #"printf '%s|' "$@""#, "sh", "-a b", "$HOME", "'q'"], timeout: .seconds(5))
        #expect(String(decoding: quoted.stdout, as: UTF8.self) == "-a b|$HOME|'q'|")  // arguments are never re-parsed by a shell
    }
}

// MARK: The real qmd

private let realQmd = ["/opt/homebrew/bin/qmd", "/usr/local/bin/qmd"].first { FileManager.default.isExecutableFile(atPath: $0) }

/// The user's real qmd with every path it writes (index, config, models) moved into a temp folder, so the user's own
/// `~/.cache/qmd` and `~/.config/qmd` are never touched.
private final class IsolatedQmd: ToolEnvironment, @unchecked Sendable {
    let root: URL
    let environment: [String: String]
    init(qmd: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "qmd-real-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (qmd as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        environment["XDG_CACHE_HOME"] = root.appending(path: "cache").path
        environment["XDG_CONFIG_HOME"] = root.appending(path: "config").path
        environment["QMD_CONFIG_DIR"] = root.appending(path: "config/qmd").path
        environment["INDEX_PATH"] = nil
        environment["PWD"] = nil
        self.environment = environment
    }
    func snapshot() async -> ToolEnvironmentSnapshot { ToolEnvironmentSnapshot(environment: environment, source: .loginShell(path: "/bin/zsh"), seconds: 0) }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private func listing(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { name in
        let date = (try? FileManager.default.attributesOfItem(atPath: path + "/" + name)[.modificationDate] as? Date) ?? nil
        return "\(name) \(date?.timeIntervalSince1970 ?? 0)"
    }
}

@Suite(.enabled(if: realQmd != nil, "qmd is not installed"))
struct RealQmdTests {
    @Test func registerSearchUpdateAndRemoveAgainstAThrowawayIndex() async throws {
        let qmd = try #require(realQmd)
        let userCache = NSHomeDirectory() + "/.cache/qmd", userConfig = NSHomeDirectory() + "/.config/qmd"
        let before = (listing(userCache), listing(userConfig))

        let isolated = try IsolatedQmd(qmd: qmd)
        let workspace = isolated.root.appending(path: "My Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("# Alpha\n\nThe flux capacitor is here.\n".utf8).write(to: workspace.appending(path: "alpha.md"))
        try Data("---\ntitle: Beta\n---\n\nAnother capacitor in a qmd file.\n".utf8).write(to: workspace.appending(path: "sub/beta.qmd"))
        try Data("not indexed capacitor\n".utf8).write(to: workspace.appending(path: "note.txt"))

        let asked = Recorder<QmdConsentRequest>()
        let options = Box(QmdOptions())
        let provider = QmdSearchProvider(dependencies: QmdEngine.Dependencies(
            environment: isolated, options: { options.value }, consent: { asked.add($0); return .register }, decline: { _ in },
            updateInterval: .zero, watchFolders: false, setupPollInterval: .milliseconds(50)))

        #expect(try await provider.prepare(workspace: workspace) == .ready)
        let name = QmdMapping.collectionName(forRealRoot: realPath(workspace.path))
        #expect(asked.values.map(\.collection) == [name])
        #expect(FileManager.default.fileExists(atPath: isolated.root.appending(path: "cache/qmd/index.sqlite").path))

        // Registered with the mask that includes .qmd, and left out of default queries.
        let runner = QmdRunner(executable: qmd, environment: isolated.environment, makeSpawner: { SystemProcessSpawner(environment: $0) })
        let show = try await runner.run(["collection", "show", name], timeout: .seconds(20))
        let collection = try #require(QmdParse.collection(named: name, fromShow: String(decoding: show.stdout, as: UTF8.self)))
        #expect(collection.pattern == QmdMapping.mask && !collection.includedByDefault && realPath(collection.path) == realPath(workspace.path))

        var hits = try await collect(provider.search(SearchQuery(text: "capacitor"), in: workspace))
        #expect(Set(hits.map { $0.file.path }) == [workspace.appending(path: "alpha.md").path, workspace.appending(path: "sub/beta.qmd").path])
        #expect(hits.first { $0.file.lastPathComponent == "beta.qmd" }?.line == 5)
        #expect(hits.allSatisfy { $0.source == "qmd" && !$0.highlights.isEmpty })

        // A new file shows up after the folder changed (update before the search).
        try Data("A third capacitor.\n".utf8).write(to: workspace.appending(path: "gamma.markdown"))
        await provider.engine.markChanged(realPath(workspace.path))
        hits = try await collect(provider.search(SearchQuery(text: "third"), in: workspace))
        #expect(hits.map(\.file.lastPathComponent) == ["gamma.markdown"])

        // Semantic search switched on without its models: the setup fails with qmd's message, a semantic search says so, and
        // keyword search keeps working. The models are pointed at files that do not exist, so nothing is downloaded.
        let configFile = isolated.root.appending(path: "config/qmd/index.yml")
        var config = try String(contentsOf: configFile, encoding: .utf8)
        config = config.replacing(/(embed|generate|rerank): hf:.*/) { "\($0.1): /nonexistent/\($0.1).gguf" }
        try config.write(to: configFile, atomically: true, encoding: .utf8)
        options.value.semantic = true
        provider.setSemantic(true)
        await provider.engine.semanticSettingsChanged()
        let setup = await eventually({ await provider.engine.setupState(name) }, { if case .preparing? = $0 { false } else { true } }, timeout: .seconds(60))
        guard case .failed(let reason)? = setup else { Issue.record("setup did not fail: \(String(describing: setup))"); return }
        #expect(reason.hasPrefix(L10n.setupFailed("")) && reason.contains("/nonexistent/embed.gguf"), "\(reason)")
        await #expect(throws: QmdError.failed(status: 0, message: reason)) {
            _ = try await collect(provider.search(SearchQuery(text: "flux", isSemantic: true), in: workspace))
        }
        #expect(try await collect(provider.search(SearchQuery(text: "flux"), in: workspace)).count == 1)

        // "Disable qmd Index" removes the collection.
        let disable = try #require(provider.folderActions(for: workspace).first)
        await disable.perform()
        let list = try await runner.run(["collection", "list"], timeout: .seconds(20))
        #expect(!QmdParse.collectionNames(fromList: String(decoding: list.stdout, as: UTF8.self)).contains(name))

        #expect(listing(userCache) == before.0 && listing(userConfig) == before.1, "the user's own qmd index or config changed")
    }

    /// The whole semantic setup with the real models: about 1.6 GB downloaded into the throwaway cache, so only when asked
    /// (`MD2_QMD_SETUP_TEST=1`). `MD2_QMD_MODELS=<folder>` clones the `.gguf` files found there into the throwaway cache first
    /// (no download), which still checks the embed, the warm-up and the first semantic search.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MD2_QMD_SETUP_TEST"] == "1", "MD2_QMD_SETUP_TEST=1 runs it (downloads ~1.6 GB)"),
          .timeLimit(.minutes(60)))
    func semanticSetupThenRankedResultsOnTheFirstTry() async throws {
        let qmd = try #require(realQmd)
        let userCache = NSHomeDirectory() + "/.cache/qmd", userConfig = NSHomeDirectory() + "/.config/qmd"
        let before = (listing(userCache), listing(userConfig))
        let isolated = try IsolatedQmd(qmd: qmd)
        let models = isolated.root.appending(path: "cache/qmd/models")
        let seeded = ProcessInfo.processInfo.environment["MD2_QMD_MODELS"].flatMap { $0.isEmpty ? nil : $0 }
        if let seeded {
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: seeded) where name.hasSuffix(".gguf") {
                try FileManager.default.copyItem(atPath: seeded + "/" + name, toPath: models.appending(path: name).path)  // an APFS clone
            }
        }
        let workspace = isolated.root.appending(path: "Garden", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("# Watering plants\n\nHow often should you water a fern? Keep the soil moist but not soggy.\n".utf8).write(to: workspace.appending(path: "plants.md"))
        try Data("# Car maintenance\n\nChange the engine oil every 5000 miles and check tire pressure monthly.\n".utf8).write(to: workspace.appending(path: "car.md"))
        try Data("# Cooking rice\n\nRinse the rice, use 1.5 cups of water per cup, simmer 18 minutes.\n".utf8).write(to: workspace.appending(path: "rice.md"))

        let provider = QmdSearchProvider(dependencies: QmdEngine.Dependencies(
            environment: isolated, options: { QmdOptions(semantic: true) }, consent: { _ in .register }, decline: { _ in },
            updateInterval: .zero, watchFolders: false, setupPollInterval: .milliseconds(200)), semantic: true)
        #expect(try await provider.prepare(workspace: workspace) == .ready)
        let name = QmdMapping.collectionName(forRealRoot: realPath(workspace.path))
        var seen: [SemanticSetup] = []
        let setup = await eventually({ () -> SemanticSetup? in
            let state = await provider.engine.setupState(name)
            if let state, seen.last != state { seen.append(state) }
            return state
        }, { if case .preparing? = $0 { false } else { true } }, timeout: .seconds(55 * 60))
        print("qmd setup went through: \(seen)")
        #expect(setup == .ready)
        if seeded == nil { #expect(seen.contains { if case .preparing(let text) = $0 { text.contains("MB") || text.contains("GB") } else { false } }) }

        let hits = try await collect(provider.search(SearchQuery(text: "how do I look after a houseplant", isSemantic: true), in: workspace))
        #expect(hits.first?.file.lastPathComponent == "plants.md", "\(hits.map(\.file.lastPathComponent))")
        #expect(listing(userCache) == before.0 && listing(userConfig) == before.1, "the user's own qmd index or config changed")
    }
}
