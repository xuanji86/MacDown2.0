import ExtensionAPI
import Foundation
import Synchronization
import WorkspaceKit

/// The search panel's qmd source (PLAN 4.12): BM25 `qmd search` as you type, `qmd query` when asked for a semantic search.
/// Exists only while the extension is on; creating it starts nothing.
public final class QmdSearchProvider: SearchProvider, Sendable {
    public static let providerID = "qmd"

    public var id: String { Self.providerID }
    /// The tool's name, the same in every language.
    public var badge: String { "qmd" }
    public var capabilities: SearchCapabilities { flags.withLock { $0.semantic } ? [.keyword, .semantic] : .keyword }

    let engine: QmdEngine
    /// The semantic setup as the search page shows it.
    let setup: QmdSetupBoard
    private let flags = Mutex(Flags())
    private let owned: OwnedFolders
    private let running = Mutex<[UUID: Task<Void, Never>]>([:])

    private struct Flags {
        var semantic = false
    }

    /// Workspace folders whose collection we created, for the context menu (answered from memory).
    final class OwnedFolders: Sendable {
        let byKey = Mutex<[String: String]>([:])
    }

    init(dependencies: QmdEngine.Dependencies, semantic: Bool = false) {
        let owned = OwnedFolders()
        let board = QmdSetupBoard()
        var deps = dependencies
        let publish = deps.publishOwned
        deps.publishOwned = { map in
            owned.byKey.withLock { $0 = map }
            publish(map)
        }
        let publishSetup = deps.publishSetup
        deps.publishSetup = { version, collections, states in
            Task { @MainActor in board.apply(version: version, collections: collections, states: states) }
            publishSetup(version, collections, states)
        }
        self.owned = owned
        setup = board
        engine = QmdEngine(deps)
        flags.withLock { $0.semantic = semantic }
    }

    func setSemantic(_ on: Bool) { flags.withLock { $0.semantic = on } }

    public func prepare(workspace: URL) async throws -> SearchReadiness { await engine.prepare(workspace) }

    /// The whole result list arrives at once (qmd prints it at the end). Ends with `SearchError.truncated` after the hits when
    /// more than `query.limit` were found, with the qmd error when the run failed (for a semantic search the message says
    /// so); ends quietly when cancelled.
    public func search(_ query: SearchQuery, in workspace: URL) -> AsyncThrowingStream<SearchHit, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            let engine = engine
            let task = Task {
                do {
                    let (hits, truncated) = try await engine.search(query, in: workspace)
                    for hit in hits { continuation.yield(hit) }
                    continuation.finish(throwing: truncated ? SearchError.truncated(.hits(query.limit)) : nil)
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? nil : error)
                }
            }
            running.withLock { $0[id] = task }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.running.withLock { $0[id] = nil }
            }
        }
    }

    public func cancelAll() async {
        for task in running.withLock({ Array($0.values) }) { task.cancel() }
        await engine.cancelAll()
    }

    /// Switched off: every qmd process is stopped and nothing new starts.
    func shutdown() async {
        for task in running.withLock({ Array($0.values) }) { task.cancel() }
        await engine.shutdown()
    }

    /// While semantic search is on: `.preparing` until qmd's models are downloaded and the folder is embedded (the sparkles
    /// button waits); `.failed` with a retry. Keyword search does not wait for any of it.
    @MainActor public func semanticSetup(for workspace: URL) -> SemanticSetup {
        flags.withLock { $0.semantic } ? setup.state(for: workspace) : .ready
    }

    @MainActor public func retrySemanticSetup(for workspace: URL) {
        let engine = engine, key = workspace.fileKey
        Task { await engine.retrySetup(workspaceKey: key) }
    }

    @MainActor public func cancelSemanticSetup(for workspace: URL) {
        let engine = engine, key = workspace.fileKey
        Task { await engine.cancelSetup(workspaceKey: key) }
    }

    /// The app is quitting: the processes of searches, setups and embeds are killed before this returns.
    func terminateNow() {
        for task in running.withLock({ Array($0.values) }) { task.cancel() }
        engine.terminateNow()
    }

    public func folderActions(for folder: URL) -> [SearchFolderAction] {
        let key = folder.fileKey
        guard owned.byKey.withLock({ $0[key] }) != nil else { return [] }
        let engine = engine
        return [SearchFolderAction(title: L10n.disableIndex) { await engine.removeIndex(workspaceKey: key) }]
    }
}
