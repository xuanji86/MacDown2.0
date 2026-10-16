import Foundation
import WorkspaceKit

/// What a search provider can do (PLAN 4.12 / 4.17).
public struct SearchCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let keyword = SearchCapabilities(rawValue: 1)
    public static let semantic = SearchCapabilities(rawValue: 2)
    /// Takes `SearchQuery.isRegex` queries.
    public static let regex = SearchCapabilities(rawValue: 4)
    /// Covers every file type ("All" in the file filter), not only the files an index of its own holds.
    public static let allFiles = SearchCapabilities(rawValue: 8)
}

extension SearchQuery {
    /// What a provider must be able to do to answer this query.
    public var requiredCapabilities: SearchCapabilities {
        var needed: SearchCapabilities = isSemantic ? .semantic : .keyword
        if isRegex { needed.insert(.regex) }
        if files.showAllFiles { needed.insert(.allFiles) }
        return needed
    }
}

/// A right-click command a provider offers on a folder in the sidebar (qmd: stop indexing it).
public struct SearchFolderAction: Sendable {
    public var title: String
    public var perform: @Sendable () async -> Void

    public init(title: String, perform: @escaping @Sendable () async -> Void) {
        self.title = title
        self.perform = perform
    }
}

public enum SearchReadiness: Sendable, Equatable {
    case ready
    /// Cannot search right now; the text says why (shown instead of results).
    case unavailable(String)
}

/// Whether a provider's semantic search can run in a folder yet. A provider may have to set it up in the background first
/// (qmd downloads its models and embeds the folder); keyword search is not affected meanwhile.
public enum SemanticSetup: Sendable, Equatable {
    case ready
    /// Being set up; the text says what is happening now ("Downloading qmd’s models: 430 MB of 1.6 GB").
    case preparing(String)
    /// The setup failed or was stopped; the text says why. `retrySemanticSetup` starts it again.
    case failed(String)
}

/// A source of search results for the sidebar's search panel. The core ships `BuiltinSearchBackend`; an optional extension
/// may add more, each result is badged with `badge`.
public protocol SearchProvider: Sendable {
    /// "builtin"; matches `SearchHit.source`.
    var id: String { get }
    /// The short label of the source badge on a result ("Built-in").
    var badge: String { get }
    var capabilities: SearchCapabilities { get }
    /// Called when the user first opens the search panel for `workspace` (detect tools, ask consent, register collections).
    func prepare(workspace: URL) async throws -> SearchReadiness
    /// Hits as they are found. Ends with a `SearchError` when the query is invalid or the results were cut short.
    func search(_ query: SearchQuery, in workspace: URL) -> AsyncThrowingStream<SearchHit, any Error>
    func cancelAll() async
    /// Commands for `folder` in the sidebar's context menu. Called while the menu is built, so it must answer from memory.
    func folderActions(for folder: URL) -> [SearchFolderAction]
    /// Whether a semantic search in `workspace` can run now. Read while the search page is drawn, so it must answer from
    /// memory; observable in practice (the page follows the setup's progress).
    @MainActor func semanticSetup(for workspace: URL) -> SemanticSetup
    /// Starts the semantic setup of `workspace` again after it failed or was stopped.
    @MainActor func retrySemanticSetup(for workspace: URL)
    /// Stops a running semantic setup of `workspace` (its processes are killed); it then reads as failed, with a retry.
    @MainActor func cancelSemanticSetup(for workspace: URL)
}

extension SearchProvider {
    public func folderActions(for folder: URL) -> [SearchFolderAction] { [] }
    @MainActor public func semanticSetup(for workspace: URL) -> SemanticSetup { .ready }
    @MainActor public func retrySemanticSetup(for workspace: URL) {}
    @MainActor public func cancelSemanticSetup(for workspace: URL) {}

    /// This provider can answer `query`.
    public func canRun(_ query: SearchQuery) -> Bool { capabilities.isSuperset(of: query.requiredCapabilities) }
}

extension BuiltinSearchBackend: SearchProvider {
    public var id: String { Self.providerID }
    public var badge: String { L10n.builtinBadge }
    public var capabilities: SearchCapabilities { [.keyword, .regex, .allFiles] }
    public func prepare(workspace: URL) async throws -> SearchReadiness { .ready }
    public func cancelAll() async { cancel() }
}
