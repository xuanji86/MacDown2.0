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
}

extension SearchProvider {
    public func folderActions(for folder: URL) -> [SearchFolderAction] { [] }
}

extension BuiltinSearchBackend: SearchProvider {
    public var id: String { Self.providerID }
    public var badge: String { L10n.builtinBadge }
    public var capabilities: SearchCapabilities { [.keyword, .regex] }
    public func prepare(workspace: URL) async throws -> SearchReadiness { .ready }
    public func cancelAll() async { cancel() }
}
