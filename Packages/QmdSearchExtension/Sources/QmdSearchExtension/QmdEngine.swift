import ExtensionAPI
import Foundation
import WorkspaceKit

/// The settings, as the engine reads them when it needs them.
struct QmdOptions: Sendable, Equatable {
    var manualPath = ""
    var semantic = false
    var rerank = false
    var autoEmbed = false
    /// Folders (realpaths) the user answered "Use Built-in Search" for, or whose index they disabled.
    var declinedFolders: Set<String> = []
    /// Collections whose semantic setup (models downloaded, embedded) finished, as remembered across launches.
    var semanticReady: Set<String> = []
}

/// Where qmd is, as found by the last look.
enum QmdTool: Sendable, Equatable {
    case found(path: String, version: String)
    /// Not on the login shell's PATH (`manualPath` nil), or the path set in Settings is not an executable.
    case notFound(manualPath: String?)
    case unsupported(path: String, version: String)
    case broken(path: String, message: String)
}

struct QmdConsentRequest: Sendable, Equatable {
    var folder: URL
    var collection: String
    /// The shared index qmd writes to, `~`-abbreviated.
    var indexPath: String
}

enum QmdConsentAnswer: Sendable { case register, declined, notAsked }

/// Everything about qmd that is not UI: finding it, the workspace's collection, keeping the index fresh, running queries.
/// Nothing here runs until `prepare`, `search` or the settings pane's `detect` asks (PLAN 4.12 / 4.17).
actor QmdEngine {
    struct Dependencies: Sendable {
        var environment: any ToolEnvironment
        var makeSpawner: @Sendable ([String: String]) -> any ProcessSpawner = { SystemProcessSpawner(environment: $0) }
        var options: @Sendable () async -> QmdOptions
        var consent: @Sendable (QmdConsentRequest) async -> QmdConsentAnswer
        /// Remembers a declined folder (realpath) in the settings.
        var decline: @Sendable (String) async -> Void
        /// Workspace folders (`fileKey`) whose collection we created → its name, for the sidebar's context menu.
        var publishOwned: @Sendable ([String: String]) -> Void = { _ in }
        /// Minimum time between two `qmd update` runs.
        var updateInterval: Duration = .seconds(60)
        /// Watch prepared folders for changes (tests call `markChanged` themselves).
        var watchFolders = true
        /// The semantic setup for the search page: a version that counts up, workspace (`fileKey`) → collection, collection → setup.
        var publishSetup: @Sendable (Int, [String: String], [String: SemanticSetup]) -> Void = { _, _, _ in }
        /// Remembers in the settings that a collection's semantic setup finished (true), or forgets it.
        var rememberSetup: @Sendable (String, Bool) async -> Void = { _, _ in }
        /// How often a running setup's progress is read from qmd's model cache.
        var setupPollInterval: Duration = .milliseconds(500)
        /// The limit for one semantic search (the setup is not bound by it).
        var queryTimeout: Duration = .seconds(60)
    }

    static let searchTimeout: Duration = .seconds(10)
    static let shortTimeout: Duration = .seconds(10)
    // lazy: indexing a new folder may take up to 5 minutes, a full `qmd update` 2; a bigger tree fails with a timeout message
    static let addTimeout: Duration = .seconds(300)
    static let updateTimeout: Duration = .seconds(120)
    static let embedTimeout: Duration = .seconds(30 * 60)
    // lazy: a setup step (a model download, or embedding a folder) gets 2 hours; qmd's own embed stops after 30 minutes and the
    // rest is embedded later ("embed when idle" or "Update Embeddings Now")
    static let setupTimeout: Duration = .seconds(2 * 60 * 60)
    /// What `qmd embed` prints (and exits 0) when another embed holds qmd's lock.
    static let embedBusy = "Another embed process is already running"

    private struct AskLater: Error {}

    private struct Prepared {
        var workspaceKey: String
        var collection: String
        /// We registered it (`macdown2-…` for exactly this folder): ours to remove.
        var owned: Bool
        /// The collection is a parent folder's: qmd's top results may all lie outside this one.
        var parent = false
        /// Something changed since the last `qmd update` (or nothing is known about it yet).
        var dirty: Bool
        var lastUpdate: ContinuousClock.Instant?
        var watcher: FolderWatcher?
        /// The collection's file count from `qmd collection list`, for the setup's progress.
        var files: Int? = nil
    }

    /// What a semantic setup is doing, for its progress text.
    enum SetupStep: Sendable, Equatable {
        case starting
        case embedding(files: Int?)
        case loading
    }

    private struct SetupJob {
        let id: UUID
        let task: Task<Void, Never>
        var step: SetupStep
        /// qmd's model cache, where downloads show up.
        let models: String
    }

    private enum Slot {
        case preparing(Task<SearchReadiness, Never>)
        case ready(Prepared)
        case unavailable(String)
    }

    private let deps: Dependencies
    /// The last look for qmd (finished or still running) and the Settings path it was for.
    private var tool: (manualPath: String, task: Task<QmdTool, Never>)?
    /// By the workspace folder's realpath.
    private var slots: [String: Slot] = [:]
    /// Collections `qmd update` would run a shell command for: while there are any, the app never runs `qmd update`.
    private(set) var updatesBlockedBy: [String] = []
    private var updateTask: Task<Void, Never>?
    private var embedTask: Task<String?, Never>?
    private var embedLoop: Task<Void, Never>?
    /// Counts `updateEmbedLoop` calls, so only the one that read the newest settings acts.
    private var embedLoopCheck = 0
    private var lastEmbed: ContinuousClock.Instant?
    private var shutDown = false
    /// Running semantic setups, by collection.
    private var setupJobs: [String: SetupJob] = [:]
    /// By collection; absent = not looked at yet (or semantic search is off).
    private var setupStates: [String: SemanticSetup] = [:]
    /// Collections set up again this session because qmd answered that they had no embeddings (once each, so it cannot loop).
    private var healed: Set<String> = []
    private var setupVersion = 0
    /// Everything that runs qmd in the background (preparing a folder, updates, setups, embeds), cancelled from any thread
    /// when the app quits.
    nonisolated let live = LiveTasks()

    init(_ deps: Dependencies) { self.deps = deps }

    // MARK: Finding qmd

    /// The tool, looked for once (again when the Settings path changed, or `force`). The first call reads the login shell.
    func detect(force: Bool = false) async -> QmdTool {
        let manual = await deps.options().manualPath.trimmingCharacters(in: .whitespaces)
        if !force, let tool, tool.manualPath == manual { return await tool.task.value }
        if force { resetUnavailable() }
        let task = Task { await self.probe(manualPath: manual) }
        tool = (manual, task)
        return await task.value
    }

    private func probe(manualPath: String) async -> QmdTool {
        let snapshot = await deps.environment.snapshot()
        guard let path = snapshot.which(manualPath.isEmpty ? "qmd" : manualPath) else { return .notFound(manualPath: manualPath.isEmpty ? nil : manualPath) }
        do {
            let output = try await runner(path: path, environment: snapshot.environment).run(["--version"], timeout: Self.shortTimeout)
            let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = QmdParse.version(text) else { return .broken(path: path, message: L10n.unknownVersion(text)) }
            return QmdParse.isSupported(version) ? .found(path: path, version: version.description) : .unsupported(path: path, version: version.description)
        } catch {
            return .broken(path: path, message: error.localizedDescription)
        }
    }

    private func runner(path: String, environment: [String: String]) -> QmdRunner {
        var environment = environment
        environment["NO_COLOR"] = "1"
        return QmdRunner(executable: path, environment: environment, makeSpawner: deps.makeSpawner)
    }

    /// A runner for the qmd that was found; throws (with the note that says why) when there is none.
    private func runner() async throws -> QmdRunner { try await runner(for: await detect()) }

    private func runner(for tool: QmdTool) async throws -> QmdRunner {
        guard case .found(let path, _) = tool else { throw QmdError.failed(status: 127, message: L10n.note(for: tool)) }
        return runner(path: path, environment: await deps.environment.snapshot().environment)
    }

    /// After "Check Again" or "Ask Again for Declined Folders": folders that could not (or would not) use qmd are prepared
    /// again on the next search; a folder still in the declined setting stays declined.
    func resetUnavailable() {
        for (key, slot) in slots { if case .unavailable = slot { slots[key] = nil } }
    }

    // MARK: Preparing a folder

    func prepare(_ workspace: URL) async -> SearchReadiness {
        guard !shutDown else { return .unavailable("") }
        let realRoot = realPath(workspace.path(percentEncoded: false))
        switch slots[realRoot] {
        case .ready: return .ready
        case .unavailable(let reason): return .unavailable(reason)
        case .preparing(let task): return await task.value
        case nil: break
        }
        let task = Task { await self.makeReady(workspace, realRoot: realRoot) }
        slots[realRoot] = .preparing(task)
        let id = UUID()
        live.insert(id) { task.cancel() }
        defer { live.remove(id) }
        return await task.value
    }

    private func makeReady(_ workspace: URL, realRoot: String) async -> SearchReadiness {
        let readiness: SearchReadiness
        do {
            readiness = try await findOrRegister(workspace, realRoot: realRoot)
        } catch is CancellationError, is AskLater {
            if case .preparing = slots[realRoot] { slots[realRoot] = nil }
            return .unavailable("")
        } catch {
            readiness = .unavailable(L10n.noteFailed(error.localizedDescription))
        }
        // Cancelled (the extension was switched off, or "stop"): nothing is remembered, the next search asks again.
        if Task.isCancelled || shutDown {
            if case .preparing = slots[realRoot] { slots[realRoot] = nil }
            return .unavailable("")
        }
        if case .unavailable(let reason) = readiness, case .preparing = slots[realRoot] { slots[realRoot] = .unavailable(reason) }
        return readiness
    }

    private func findOrRegister(_ workspace: URL, realRoot: String) async throws -> SearchReadiness {
        let tool = await detect()
        guard case .found = tool else { return .unavailable(L10n.note(for: tool)) }
        let runner = try await runner(for: tool)
        let collections = try await listCollections(runner)
        updatesBlockedBy = collections.filter(\.hasUpdateCommand).map(\.name)
        try Task.checkCancellation()

        if let existing = QmdMapping.covering(collections, realRoot: realRoot) {
            let exact = realPath(existing.path) == realRoot
            let owned = existing.name.hasPrefix(QmdMapping.ownPrefix) && exact
            // Ours but still in the user's default queries: a registration that was interrupted before `exclude`.
            if owned, existing.includedByDefault { _ = try await runner.run(["collection", "exclude", existing.name], timeout: Self.shortTimeout) }
            // Nothing is known about how fresh it is: the first search runs `qmd update`.
            await adopt(workspace, realRoot: realRoot, Prepared(workspaceKey: workspace.fileKey, collection: existing.name, owned: owned, parent: !exact, dirty: true, files: existing.files))
            return .ready
        }

        if await deps.options().declinedFolders.contains(realRoot) { return .unavailable("") }
        var name = QmdMapping.collectionName(forRealRoot: realRoot)
        let taken = Set(collections.map(\.name))
        if taken.contains(name) {
            let base = name
            name = (2...).lazy.map { "\(base)-\($0)" }.first { !taken.contains($0) }!
        }
        let request = QmdConsentRequest(folder: workspace, collection: name, indexPath: await indexPath())
        switch await deps.consent(request) {
        case .notAsked:
            throw AskLater()  // no window to ask in: ask on the next search
        case .declined:
            await deps.decline(realRoot)
            return .unavailable("")
        case .register:
            try Task.checkCancellation()
            guard !shutDown else { throw CancellationError() }
            do {
                _ = try await runner.run(["collection", "add", realRoot, "--name", name, "--mask", QmdMapping.mask], timeout: Self.addTimeout)
            } catch let error as QmdError {
                // qmd saves the collection before indexing: one that failed half-way must not land in default queries.
                // (Switched off mid-add: no new process; the next prepare finds it and excludes it.)
                _ = try? await runner.run(["collection", "exclude", name], timeout: Self.shortTimeout)
                throw error
            }
            // Kept out of the user's own `qmd search` / `qmd query` without `-c` (and their agents').
            _ = try await runner.run(["collection", "exclude", name], timeout: Self.shortTimeout)
            await adopt(workspace, realRoot: realRoot, Prepared(workspaceKey: workspace.fileKey, collection: name, owned: true, dirty: false, lastUpdate: .now, files: nil))
            return .ready
        }
    }

    private func adopt(_ workspace: URL, realRoot: String, _ prepared: Prepared) async {
        var prepared = prepared
        if deps.watchFolders {
            // `ignoreSelf: false`: the app's own saves change the files qmd indexes too.
            let watcher = FolderWatcher(roots: [workspace], debounce: 1, ignoreSelf: false) { [weak self] _ in
                Task { await self?.markChanged(realRoot) }
            }
            watcher.start()
            prepared.watcher = watcher
        }
        slots[realRoot] = .ready(prepared)
        publishOwned()
        await updateEmbedLoop()
        await ensureSetup(prepared.collection)
    }

    /// `qmd collection list` has no JSON (2.8.3 ignores `--format json` there) and does not print folders, so each
    /// collection is looked up with `qmd collection show`, a few at a time; the result keeps the listing's order.
    // lazy: one process per collection (~0.2 s each), 4 at once; upgrade: read qmd's YAML config, or a JSON listing if qmd grows one
    private func listCollections(_ runner: QmdRunner) async throws -> [QmdCollection] {
        let list = try await runner.run(["collection", "list"], timeout: Self.shortTimeout)
        let listing = String(decoding: list.stdout, as: UTF8.self)
        let names = QmdParse.collectionNames(fromList: listing)
        let files = QmdParse.fileCounts(fromList: listing)
        var shown = [QmdCollection?](repeating: nil, count: names.count)
        try await withThrowingTaskGroup(of: (Int, QmdCollection?).self) { group in
            func show(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let show = try await runner.run(["collection", "show", names[index]], timeout: Self.shortTimeout)
                    var collection = QmdParse.collection(named: names[index], fromShow: String(decoding: show.stdout, as: UTF8.self))
                    collection?.files = files[names[index]]
                    return (index, collection)
                }
            }
            var next = 0
            while next < min(4, names.count) { show(next); next += 1 }
            while let (index, collection) = try await group.next() {
                shown[index] = collection
                if next < names.count { show(next); next += 1 }
            }
        }
        return shown.compactMap(\.self)
    }

    private func indexPath() async -> String {
        let environment = await deps.environment.snapshot().environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let path = QmdFiles.cacheDirectory(environment) + "/index.sqlite"
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Freshness

    func markChanged(_ realRoot: String) {
        guard case .ready(var prepared) = slots[realRoot] else { return }
        prepared.dirty = true
        slots[realRoot] = .ready(prepared)
    }

    /// Before a search: `qmd update` when the folder changed and the last one was over `updateInterval` ago. qmd 2.8.3's
    /// `update` takes no `-c` (it is accepted and ignored), so every collection is re-indexed; and it first runs each
    /// collection's own update command (`git pull`, …), so with any such collection the app never runs it.
    private func refresh(_ realRoot: String) async {
        guard case .ready(let prepared) = slots[realRoot], prepared.dirty else { return }
        if let last = prepared.lastUpdate, ContinuousClock.now - last < deps.updateInterval { return }
        if let updateTask { return await updateTask.value }
        // Registered before any suspension: a second search (another window) joins this one instead of starting its own.
        let task = Task { await self.update() }
        updateTask = task
        let id = UUID()
        live.insert(id) { task.cancel() }
        await task.value
        live.remove(id)
        if updateTask == task { updateTask = nil }
    }

    private func update() async {
        guard let runner = try? await runner() else { return }
        let now = ContinuousClock.now
        let ready = slots.compactMap { key, slot -> String? in
            if case .ready = slot { return key }
            return nil
        }
        func mark(dirty: Bool?) {
            for key in ready {
                guard case .ready(var p) = slots[key] else { continue }
                p.lastUpdate = now  // tried now: the next try waits `updateInterval`
                if let dirty { p.dirty = dirty }
                slots[key] = .ready(p)
            }
        }
        do {
            // The collections as they are now: one may have gained an update command since the folder was prepared.
            updatesBlockedBy = try await listCollections(runner).filter(\.hasUpdateCommand).map(\.name)
            guard updatesBlockedBy.isEmpty else {
                qmdLog.info("qmd update skipped: collections with an update command: \(self.updatesBlockedBy.joined(separator: ", "), privacy: .public)")
                return mark(dirty: nil)
            }
            // One update re-indexes them all; a change made while it runs marks its folder again.
            mark(dirty: false)
            _ = try await runner.run(["update"], timeout: Self.updateTimeout)
        } catch {
            qmdLog.error("qmd update failed: \(error.localizedDescription, privacy: .public)")
            mark(dirty: true)  // try again after `updateInterval`
        }
    }

    // MARK: Searching

    /// The hits (at most `query.limit`) and whether more were cut off.
    func search(_ query: SearchQuery, in workspace: URL) async throws -> (hits: [SearchHit], truncated: Bool) {
        guard await prepare(workspace) == .ready else { return ([], false) }
        let realRoot = realPath(workspace.path(percentEncoded: false))
        await refresh(realRoot)
        guard case .ready(let prepared) = slots[realRoot] else { return ([], false) }
        let runner = try await runner()
        let semantic = query.isSemantic
        // `qmd query` runs only once the models are there and the folder is embedded; the setup does that in the background.
        if semantic {
            await ensureSetup(prepared.collection)
            switch setupStates[prepared.collection] {
            case .ready?: break
            case .failed(let reason)?: throw QmdError.failed(status: 0, message: reason)
            case .preparing?, nil: throw QmdError.failed(status: 0, message: L10n.semanticNotReady)
            }
        }
        // A parent folder's collection: qmd ranks the whole collection, so ask for more and keep this folder's.
        // lazy: 500 results from a parent collection; past that a folder's matches can be crowded out (then the built-in search answers)
        let count = prepared.parent ? 500 : max(1, min(semantic ? 30 : 50, query.limit))
        var arguments = [semantic ? "query" : "search", "-c", prepared.collection, "-n", String(count), "--format", "json", "--full-path"]
        if semantic, await !deps.options().rerank { arguments.append("--no-rerank") }
        arguments += ["--", query.text]  // a query may start with "-"
        let output: QmdOutput
        do {
            output = try await runner.run(arguments, timeout: semantic ? deps.queryTimeout : Self.searchTimeout)
        } catch let error as QmdError where semantic {
            throw QmdError.failed(status: 1, message: L10n.semanticFailed(error.localizedDescription))
        }
        // The sidebar's ignore rules apply here too (qmd's mask knows nothing of `_site`, `*_files`, …).
        let base = workspace.pathComponents.count
        let results = try QmdParse.results(output.stdout)
        // Nothing at all, and qmd says documents lack embeddings: the setup remembered for this collection no longer holds
        // (the index was rebuilt, …). Set it up again, once per session.
        if semantic, results.isEmpty, output.stderr.contains("need embeddings"), healed.insert(prepared.collection).inserted {
            qmdLog.info("qmd query found nothing and reports missing embeddings: setting \(prepared.collection, privacy: .public) up again")
            await deps.rememberSetup(prepared.collection, false)
            startSetup(prepared.collection, models: await modelsDirectory())
        }
        let terms = QmdMapping.terms(of: query.text)
        let inWorkspace = results.compactMap {
            QmdMapping.hit($0, workspace: workspace, realRoot: realRoot, terms: terms, wholeWords: semantic, source: QmdSearchProvider.providerID)
        }
        // Every one of a full page was elsewhere in the parent collection: this folder's matches may be further down.
        if prepared.parent, inWorkspace.isEmpty, results.count >= count { throw QmdError.failed(status: 0, message: L10n.crowdedOut) }
        let hits = inWorkspace.filter { !query.files.ignore.ignores(components: Array($0.file.pathComponents.dropFirst(base)), lastIsDirectory: false) }
        return (Array(hits.prefix(query.limit)), hits.count > query.limit)
    }

    // MARK: Disabling a folder's index

    /// "Disable qmd Index": removes the collection we created for that folder (never a user's own) and stops using qmd there.
    func removeIndex(workspaceKey: String) async {
        guard let (realRoot, prepared) = slots.lazy.compactMap({ key, slot -> (String, Prepared)? in
            if case .ready(let p) = slot, p.workspaceKey == workspaceKey, p.owned { return (key, p) }
            return nil
        }).first else { return }
        prepared.watcher?.stop()
        slots[realRoot] = .unavailable("")
        publishOwned()
        cancelSetup(prepared.collection, forget: true)
        await deps.rememberSetup(prepared.collection, false)
        await deps.decline(realRoot)
        do {
            _ = try await runner().run(["collection", "remove", prepared.collection], timeout: Self.shortTimeout)
        } catch {
            qmdLog.error("qmd collection remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publishOwned() {
        var owned: [String: String] = [:]
        for case .ready(let p) in slots.values where p.owned { owned[p.workspaceKey] = p.collection }
        deps.publishOwned(owned)
        publishSetup()
    }

    // MARK: Semantic setup

    /// Before semantic search works in a collection, qmd needs its models (the embedding model, ~330 MB, and the query
    /// expansion model, ~1.3 GB; the reranker, ~640 MB, when reranking is on) and the collection's embeddings. qmd fetches
    /// models on first use, which no 60 s search survives, so a setup job does it in the background when semantic search is
    /// switched on or a folder is prepared while it is on: `qmd embed -c` (fetches the embedding model, embeds), then one
    /// throwaway `qmd query` (fetches the expansion model and, unless `--no-rerank`, the reranker). Neither runs a
    /// collection's update command (only `qmd update` does). Not `qmd pull`: it also fetches the reranker, and without a
    /// network it deletes the models it has.
    ///
    /// Done is remembered per collection across launches (`QmdOptions.semanticReady`) and believed while the models are still
    /// in qmd's cache; a semantic search that finds nothing because qmd reports missing embeddings sets it up again.
    private func ensureSetup(_ collection: String) async {
        guard !shutDown, setupJobs[collection] == nil, setupStates[collection] == nil else { return }
        let options = await deps.options()
        guard options.semantic, !shutDown, setupJobs[collection] == nil, setupStates[collection] == nil else { return }
        let environment = await deps.environment.snapshot().environment
        let cache = QmdFiles.cacheDirectory(environment)
        let remembered = options.semanticReady.contains(collection)
            && QmdFiles.modelsPresent(cache: cache, config: QmdFiles.configDirectory(environment), rerank: options.rerank)
        guard setupJobs[collection] == nil, setupStates[collection] == nil else { return }  // another call got here first
        if remembered {
            setupStates[collection] = .ready
            publishSetup()
        } else {
            startSetup(collection, models: cache + "/models")
        }
    }

    private func modelsDirectory() async -> String { QmdFiles.cacheDirectory(await deps.environment.snapshot().environment) + "/models" }

    private func startSetup(_ collection: String, models: String) {
        guard !shutDown, setupJobs[collection] == nil else { return }
        let id = UUID()
        let task = Task { await self.runSetup(collection, id: id) }
        setupJobs[collection] = SetupJob(id: id, task: task, step: .starting, models: models)
        live.insert(id) { task.cancel() }
        setupStates[collection] = .preparing(L10n.setupText(.starting))
        publishSetup()
    }

    private func runSetup(_ collection: String, id: UUID) async {
        let interval = deps.setupPollInterval
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.showProgress(collection, id: id)
                try? await Task.sleep(for: interval)
            }
        }
        var outcome: SemanticSetup
        do {
            try await setUp(collection, id: id)
            outcome = .ready
        } catch {
            outcome = error is CancellationError || Task.isCancelled ? .failed(L10n.setupStopped) : .failed(L10n.setupFailed(error.localizedDescription))
            if case .failed(let reason) = outcome { qmdLog.error("qmd semantic setup of \(collection, privacy: .public): \(reason, privacy: .public)") }
        }
        poller.cancel()
        live.remove(id)
        // Superseded: semantic search was switched off, the index disabled, or the extension switched off meanwhile.
        guard setupJobs[collection]?.id == id else { return }
        if outcome == .ready {
            await deps.rememberSetup(collection, true)
            guard setupJobs[collection]?.id == id else { return }
        }
        setupJobs[collection] = nil
        setupStates[collection] = outcome
        publishSetup()
    }

    private func setUp(_ collection: String, id: UUID) async throws {
        let runner = try await runner()
        // qmd runs one `embed` at a time and a second one only prints a notice: let ours finish first.
        if let embedTask { _ = await embedTask.value }
        try Task.checkCancellation()
        let files = slots.values.lazy.compactMap { slot -> Int?? in
            if case .ready(let p) = slot, p.collection == collection { return p.files }
            return nil
        }.first ?? nil
        setStep(collection, id: id, .embedding(files: files))
        let embed = try await runner.run(["embed", "-c", collection], timeout: Self.setupTimeout, utility: true)
        if String(decoding: embed.stdout, as: UTF8.self).contains(Self.embedBusy) { throw QmdError.failed(status: 0, message: L10n.embedBusy) }
        try Task.checkCancellation()
        setStep(collection, id: id, .loading)
        // A text no document holds: a strong keyword match would skip the expansion model (and the cache key is new each time).
        var arguments = ["query", "-c", collection, "-n", "1", "--format", "json"]
        if await !deps.options().rerank { arguments.append("--no-rerank") }
        arguments += ["--", "macdown2 setup \(id.uuidString.prefix(8).lowercased())"]
        _ = try await runner.run(arguments, timeout: Self.setupTimeout)
        try Task.checkCancellation()
    }

    private func setStep(_ collection: String, id: UUID, _ step: SetupStep) {
        guard setupJobs[collection]?.id == id else { return }
        setupJobs[collection]?.step = step
        showProgress(collection, id: id)
    }

    /// A model being downloaded says how far it got; otherwise the step.
    private func showProgress(_ collection: String, id: UUID) {
        guard let job = setupJobs[collection], job.id == id else { return }
        let text = QmdFiles.downloads(in: job.models).map { L10n.downloadingText(done: $0.done, total: $0.total) } ?? L10n.setupText(job.step)
        guard setupStates[collection] != .preparing(text) else { return }
        setupStates[collection] = .preparing(text)
        publishSetup()
    }

    /// Stops a running setup. `forget`: nothing is shown afterwards (semantic search off, index disabled); otherwise it reads
    /// as stopped, with a retry.
    private func cancelSetup(_ collection: String, forget: Bool) {
        guard let job = setupJobs[collection] else {
            if forget { setupStates[collection] = nil }
            return
        }
        job.task.cancel()
        if forget {
            setupJobs[collection] = nil
            setupStates[collection] = nil
            live.remove(job.id)
        }
        // Otherwise `runSetup` ends with "stopped" once qmd is gone.
    }

    /// The search page's Cancel.
    func cancelSetup(workspaceKey: String) {
        guard let collection = collection(workspaceKey: workspaceKey) else { return }
        cancelSetup(collection, forget: false)
    }

    /// The search page's Retry, after a failed or stopped setup.
    func retrySetup(workspaceKey: String) async {
        guard let collection = collection(workspaceKey: workspaceKey), setupJobs[collection] == nil else { return }
        if case .ready? = setupStates[collection] { return }
        startSetup(collection, models: await modelsDirectory())
    }

    /// Semantic search or reranking was switched. Off: every setup stops and nothing is shown. On (or reranking changed,
    /// which may need another model): every prepared folder's collection that is not being set up is looked at again.
    func semanticSettingsChanged() async {
        let options = await deps.options()
        if options.semantic {
            for collection in Array(setupStates.keys) where setupJobs[collection] == nil { setupStates[collection] = nil }
        } else {
            for collection in Set(setupJobs.keys).union(setupStates.keys) { cancelSetup(collection, forget: true) }
        }
        publishSetup()
        guard options.semantic else { return }
        for collection in Set(slots.values.compactMap { slot -> String? in if case .ready(let p) = slot { p.collection } else { nil } }) {
            await ensureSetup(collection)
        }
    }

    /// The setup state of `collection` (tests).
    func setupState(_ collection: String) -> SemanticSetup? { setupStates[collection] }

    private func collection(workspaceKey: String) -> String? {
        slots.values.lazy.compactMap { slot -> String? in
            if case .ready(let p) = slot, p.workspaceKey == workspaceKey { return p.collection }
            return nil
        }.first
    }

    private func publishSetup() {
        var collections: [String: String] = [:]
        for case .ready(let p) in slots.values { collections[p.workspaceKey] = p.collection }
        setupVersion += 1
        deps.publishSetup(setupVersion, collections, setupStates)
    }

    // MARK: Embeddings (semantic search only)

    /// Every 5 minutes, while semantic search and "embed when idle" are on and a folder is prepared: `qmd embed` for the
    /// prepared collections when the Mac has been idle for 2 minutes, runs on power or more than half its battery, and the
    /// last run is 30 minutes ago. Called when a folder is prepared and when either setting changes: the loop only runs
    /// while it could embed something.
    func updateEmbedLoop() async {
        embedLoopCheck += 1
        let check = embedLoopCheck
        let options = await deps.options()
        guard check == embedLoopCheck else { return }  // a later call read newer settings
        let prepared = slots.values.contains { if case .ready = $0 { true } else { false } }
        if !options.semantic || !options.autoEmbed || shutDown || !prepared {
            embedLoop?.cancel()
            embedLoop = nil
        } else if embedLoop == nil {
            embedLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await self?.embedIfIdle()
                }
            }
        }
    }

    private func embedIfIdle() async {
        let options = await deps.options()
        guard options.semantic, options.autoEmbed, !shutDown, embedTask == nil else { return }
        if let lastEmbed, ContinuousClock.now - lastEmbed < .seconds(30 * 60) { return }
        guard QmdIdle.isIdle(seconds: 120), QmdIdle.hasPower() else { return }
        _ = await embed()
    }

    /// `qmd embed -c` for every prepared collection, at utility priority. Returns the error text, nil on success.
    func embed() async -> String? {
        if let embedTask { return await embedTask.value }
        // One `qmd embed` at a time (qmd skips a second one): a running setup embeds first.
        for job in setupJobs.values { await job.task.value }
        if let embedTask { return await embedTask.value }
        let names = Set(slots.values.compactMap { slot -> String? in
            if case .ready(let p) = slot { return p.collection }
            return nil
        })
        guard !names.isEmpty else { return L10n.nothingToEmbed }
        let runner: QmdRunner
        do { runner = try await self.runner() } catch { return error.localizedDescription }
        let task = Task { () -> String? in
            for name in names.sorted() {
                do {
                    _ = try await runner.run(["embed", "-c", name], timeout: Self.embedTimeout, utility: true)
                } catch {
                    return error.localizedDescription
                }
            }
            return nil
        }
        embedTask = task
        let id = UUID()
        live.insert(id) { task.cancel() }
        let result = await task.value
        live.remove(id)
        embedTask = nil
        lastEmbed = .now
        return result
    }

    // MARK: Stopping

    /// Stops every qmd process this engine started (their process groups are killed); prepared folders stay prepared.
    func cancelAll() {
        tool?.task.cancel()
        updateTask?.cancel()
        embedTask?.cancel()
        for case .preparing(let task) in slots.values { task.cancel() }
    }

    /// The extension was switched off: stop everything, forget everything, start nothing more. Collections stay registered.
    func shutdown() {
        shutDown = true
        cancelAll()
        embedLoop?.cancel()
        embedLoop = nil
        for case .ready(let p) in slots.values { p.watcher?.stop() }
        slots = [:]
        for collection in Array(setupJobs.keys) { cancelSetup(collection, forget: true) }
        setupStates = [:]
        deps.publishOwned([:])
        publishSetup()
    }

    /// The app is quitting: every setup and embed is cancelled now, from the caller's thread, which kills their qmd processes.
    nonisolated func terminateNow() { live.cancelAll() }
}
