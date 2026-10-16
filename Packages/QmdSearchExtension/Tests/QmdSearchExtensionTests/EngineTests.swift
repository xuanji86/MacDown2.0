import ExtensionAPI
import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

struct EngineTests {
    @Test func aFolderInsideAUsersCollectionReusesItWithoutAsking() async throws {
        let parent = try temporaryFolder("notes")
        let workspace = parent.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let real = realPath(workspace.path)
        let search = #"[{"file":"\#(real)/ch1.md","line":4,"snippet":"@@ -3,2 @@ (2 before, 0 after)\n\nthe needle here\n"},{"file":"\#(realPath(parent.path))/elsewhere.md","line":1}]"#
        let qmd = FakeQmd(answer: standardAnswers(collections: [("notes", realPath(parent.path), nil)], search: search))
        let asked = Recorder<QmdConsentRequest>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), asked: asked)

        #expect(try await provider.prepare(workspace: workspace) == .ready)
        #expect(asked.values.isEmpty)
        #expect(!qmd.commands.contains { $0.first == "collection" && ["add", "exclude"].contains($0[1]) })
        let hits = try await collect(provider.search(SearchQuery(text: "-x needle"), in: workspace))
        #expect(hits.map(\.file.lastPathComponent) == ["ch1.md"])  // elsewhere.md is outside the workspace
        #expect(hits.first?.line == 4 && hits.first?.snippet == "the needle here")
        #expect(qmd.commands.last == ["search", "-c", "notes", "-n", "500", "--format", "json", "--full-path", "--", "-x needle"])
        #expect(qmd.lastEnvironment?["NO_COLOR"] == "1" && qmd.lastEnvironment?["PATH"]?.contains("/usr/bin") == true)
        #expect(provider.folderActions(for: workspace).isEmpty)  // not ours: nothing to remove
    }

    @Test func aNewFolderIsRegisteredOnlyAfterConsentAndKeptOutOfDefaultQueries() async throws {
        let workspace = try temporaryFolder("My Book")
        let real = realPath(workspace.path)
        let qmd = FakeQmd(answer: standardAnswers(collections: [("other", "/elsewhere", nil)]))
        let asked = Recorder<QmdConsentRequest>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(extra: ["XDG_CACHE_HOME": "/caches"]), asked: asked)

        #expect(try await provider.prepare(workspace: workspace) == .ready)
        let request = try #require(asked.values.first)
        let name = QmdMapping.collectionName(forRealRoot: real)
        #expect(request == QmdConsentRequest(folder: workspace, collection: name, indexPath: "/caches/qmd/index.sqlite"))
        let registration = qmd.commands.filter { $0.first == "collection" && ["add", "exclude"].contains($0[1]) }
        #expect(registration == [["collection", "add", real, "--name", name, "--mask", "**/*.{md,markdown,qmd}"], ["collection", "exclude", name]])

        // Prepared once: the panel opening again, or a search, asks nothing more.
        #expect(try await provider.prepare(workspace: workspace) == .ready)
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        #expect(asked.values.count == 1)
        #expect(Array(qmd.commands.last?.prefix(3) ?? []) == ["search", "-c", name])
        #expect(!qmd.commands.contains(["update"]))  // just indexed by `collection add`
        #expect(provider.folderActions(for: workspace).map(\.title) == [L10n.disableIndex])
    }

    @Test func declining_keepsTheBuiltinSearchAndIsRemembered() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: []))
        let declined = Recorder<String>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), consent: .declined, declined: declined)
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(declined.values == [realPath(workspace.path)])
        #expect(!qmd.commands.contains { $0.count > 1 && $0[1] == "add" })
        #expect(try await collect(provider.search(SearchQuery(text: "x"), in: workspace)).isEmpty)
        #expect(!qmd.commands.contains { $0.first == "search" })

        // A folder declined earlier (in the settings) is not asked about again.
        let asked = Recorder<QmdConsentRequest>()
        let again = makeProvider(qmd: qmd, environment: try FakeEnvironment(), options: QmdOptions(declinedFolders: [realPath(workspace.path)]), asked: asked)
        #expect(try await again.prepare(workspace: workspace) == .unavailable(""))
        #expect(asked.values.isEmpty)
    }

    @Test func noWindowToAskInMeansAskingOnTheNextSearch() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: []))
        let asked = Recorder<QmdConsentRequest>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), consent: .notAsked, asked: asked)
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(asked.values.count == 2)
    }

    @Test func notInstalledOrTooOldFallsBackWithANote() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: []))
        let missing = makeProvider(qmd: qmd, environment: try FakeEnvironment(), options: QmdOptions(manualPath: "/nowhere/qmd"))
        #expect(try await missing.prepare(workspace: workspace) == .unavailable(L10n.notExecutable("/nowhere/qmd")))
        #expect(qmd.spawns == 0)

        let old = FakeQmd(answer: standardAnswers(collections: [], version: "qmd 2.7.0 (abc)"))
        let environment = try FakeEnvironment()
        let provider = makeProvider(qmd: old, environment: environment)
        let readiness = try await provider.prepare(workspace: workspace)
        #expect(readiness == .unavailable(L10n.tooOld(path: environment.bin.appending(path: "qmd").path, version: "2.7.0")))
        #expect(old.commands == [["--version"]])
    }

    @Test func theIndexIsUpdatedBeforeASearchOnlyWhenTheFolderChangedAndAMinuteHasPassed() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", real, nil)]))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment())
        func updates() -> Int { qmd.commands.filter { $0 == ["update"] }.count }
        func search() async throws { _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace)) }

        try await search()
        #expect(updates() == 1)  // a reused collection: nothing known about how fresh it is
        try await search()
        #expect(updates() == 1)  // nothing changed
        await provider.engine.markChanged(real)
        try await search()
        #expect(updates() == 1)  // changed, but the last update was less than a minute ago

        let quick = makeProvider(qmd: qmd, environment: try FakeEnvironment(), updateInterval: .zero)
        _ = try await collect(quick.search(SearchQuery(text: "x"), in: workspace))
        #expect(updates() == 2)
        _ = try await collect(quick.search(SearchQuery(text: "x"), in: workspace))
        #expect(updates() == 2)  // no change since
        await quick.engine.markChanged(real)
        _ = try await collect(quick.search(SearchQuery(text: "x"), in: workspace))
        #expect(updates() == 3)
        #expect(!qmd.commands.contains { $0.first == "embed" })  // never in the search path
    }

    @Test func theSidebarsIgnoreRulesApplyToQmdsResults() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let search = #"[{"file":"\#(real)/_site/copy.md","line":1},{"file":"\#(real)/a_files/b.md","line":1},{"file":"\#(real)/keep.md","line":1}]"#
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", real, nil)], search: search))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment())
        #expect(try await collect(provider.search(SearchQuery(text: "x"), in: workspace)).map(\.file.lastPathComponent) == ["keep.md"])
    }

    @Test func aCollectionWithAnUpdateCommandStopsAutomaticUpdates() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", realPath(workspace.path), nil), ("repo", "/repo", "git pull")]))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), updateInterval: .zero)
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        #expect(!qmd.commands.contains(["update"]))
        #expect(await provider.engine.updatesBlockedBy == ["repo"])
    }

    @Test func semanticSearchUsesQueryAndFailsWithAClearMessage() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", realPath(workspace.path), nil)]))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), options: QmdOptions(semantic: true))
        #expect(provider.capabilities == [.keyword, .semantic])
        _ = try await provider.prepare(workspace: workspace)
        #expect(await eventually({ await provider.engine.setupState("mine") }, { $0 == .ready }) == .ready)  // SetupTests
        _ = try await collect(provider.search(SearchQuery(text: "how it works", isSemantic: true), in: workspace))
        #expect(qmd.commands.last == ["query", "-c", "mine", "-n", "30", "--format", "json", "--full-path", "--no-rerank", "--", "how it works"])

        let stderr = try fixtureText("query-no-model-stderr.txt")
        qmd.answer = { args in args.first == "query" ? .init(stderr: stderr, status: 1) : standardAnswers(collections: [("mine", realPath(workspace.path), nil)])(args) }
        await #expect(throws: QmdError.failed(status: 1, message: L10n.semanticFailed(#"Error: No model file found at "/nonexistent/gen.gguf""#))) {
            _ = try await collect(provider.search(SearchQuery(text: "how", isSemantic: true), in: workspace))
        }
        // Keyword search still works.
        #expect(try await collect(provider.search(SearchQuery(text: "how"), in: workspace)).isEmpty)

        qmd.answer = standardAnswers(collections: [("mine", realPath(workspace.path), nil)])
        let reranking = makeProvider(qmd: qmd, environment: try FakeEnvironment(), options: QmdOptions(semantic: true, rerank: true))
        _ = try await reranking.prepare(workspace: workspace)
        #expect(await eventually({ await reranking.engine.setupState("mine") }, { $0 == .ready }) == .ready)
        _ = try await collect(reranking.search(SearchQuery(text: "how", isSemantic: true), in: workspace))
        #expect(qmd.commands.last?.first == "query" && qmd.commands.last?.contains("--no-rerank") == false)
        #expect(makeProvider(qmd: qmd, environment: try FakeEnvironment()).capabilities == .keyword)
    }

    @Test func disablingTheIndexRemovesOnlyOurCollectionAndStopsAsking() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: []))
        let declined = Recorder<String>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), declined: declined)
        #expect(try await provider.prepare(workspace: workspace) == .ready)
        let action = try #require(provider.folderActions(for: workspace).first)
        await action.perform()
        let name = QmdMapping.collectionName(forRealRoot: realPath(workspace.path))
        #expect(qmd.commands.last == ["collection", "remove", name])
        #expect(declined.values == [realPath(workspace.path)])
        #expect(provider.folderActions(for: workspace).isEmpty)
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
    }
}

// PLAN 6.1 "extension on/off": switched off, nothing of qmd exists; switched on, nothing runs until the search panel asks.
@MainActor private final class Host: ExtensionHost {
    let settings: ExtensionSettingsStore
    let toolEnvironment: any ToolEnvironment
    var providers: [any SearchProvider] = []
    init(defaults: UserDefaults, environment: any ToolEnvironment) {
        settings = ExtensionSettingsStore(defaults: defaults, extension: QmdSearchExtension.id)
        toolEnvironment = environment
    }
    func register(flavor: any DocumentFlavor) { Issue.record("qmd registers no flavor") }
    func register(searchProvider: any SearchProvider) { providers.append(searchProvider) }
}

@MainActor private final class HostProvider: ExtensionHostProvider {
    let defaults = UserDefaults(suiteName: "qmd-test.\(UUID().uuidString)")!
    let environment: LoginShellEnvironment
    let spawner = CountingSpawner()
    var hosts: [Host] = []
    var revoked: [ExtensionID] = []
    init() { environment = LoginShellEnvironment(spawner: spawner, processEnvironment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin"]) }
    func host(for id: ExtensionID) -> any ExtensionHost {
        let host = Host(defaults: defaults, environment: environment)
        hosts.append(host)
        return host
    }
    func revokeRegistrations(of id: ExtensionID) {
        revoked.append(id)
        hosts.forEach { $0.providers.removeAll() }
    }
}

final class CountingSpawner: ProcessSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var spawns: Int { lock.withLock { n } }
    func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        lock.withLock { n += 1 }
        return ProcessOutput(stdout: Data(), status: 1)
    }
}

@MainActor struct ExtensionStateTests {
    @Test func offByDefault_neverActivatedNothingSpawnedNoEnvironmentRead() async {
        let backend = HostProvider()
        let registry = ExtensionRegistry([QmdSearchExtension.self], defaults: backend.defaults, provider: backend)
        await registry.start()
        #expect(QmdSearchExtension.id == "qmd-search" && !QmdSearchExtension.enabledByDefault)
        #expect(registry.active.isEmpty)
        #expect(backend.hosts.isEmpty)  // activate never ran: not even a host was asked for
        #expect(backend.spawner.spawns == 0)
        #expect(await backend.environment.state() == .notNeeded)
        #expect(registry.extensions[0].settingsPane() == nil)
        #expect(backend.defaults.object(forKey: "extension.qmd-search.enabled") as? Bool == false)
    }

    @Test func onActivateOnlyRegistersTheProvider() async {
        let backend = HostProvider()
        backend.defaults.set(true, forKey: ExtensionRegistry.enabledKey(QmdSearchExtension.id))
        let registry = ExtensionRegistry([QmdSearchExtension.self], defaults: backend.defaults, provider: backend)
        await registry.start()
        #expect(registry.active == ["qmd-search"])
        #expect(backend.hosts.first?.providers.map(\.id) == ["qmd"])
        #expect(backend.hosts.first?.providers.first?.badge == "qmd")
        #expect(backend.spawner.spawns == 0)
        #expect(await backend.environment.state() == .notNeeded)  // detection waits for the search panel
        #expect(registry.extensions[0].settingsPane() != nil)

        await registry.setEnabled(false, for: QmdSearchExtension.id)
        #expect(backend.revoked == ["qmd-search"] && backend.hosts.first?.providers.isEmpty == true)
        #expect(registry.extensions[0].settingsPane() == nil)
        #expect(backend.spawner.spawns == 0)
    }
}
