import ExtensionAPI
import Foundation
import Observation
import SwiftUI
import WorkspaceKit

/// One file's hits in the results list.
struct SearchGroup: Identifiable {
    let file: URL
    /// The folder of `file` below the search root ("" for a file directly in it): what is shown under the name.
    let folder: String
    var hits: [SearchHit]
    var id: String { file.fileKey }
}

/// What the search page shows besides the results.
enum SearchStatus: Equatable {
    case idle
    /// Nothing to search in: no workspace and no active document yet (or its folder is the volume root).
    case noScope
    case searching
    case finished
    /// The query itself is wrong (a bad regular expression).
    case failed(String)
}

/// One window's search page (PLAN 4.12): the query, the results of the providers, which result is selected. Searches run
/// off the main thread inside the providers; this only receives their streams, in batches.
@MainActor @Observable
final class SearchModel {
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    var isRegex = false { didSet { if isRegex != oldValue { start() } } }
    /// The selected result (`SearchHit.id`).
    var selection: String?
    /// Counts up when ⌘⇧F asks for the field to take focus.
    private(set) var focusTick = 0
    private(set) var groups: [SearchGroup] = []
    private(set) var status = SearchStatus.idle
    /// Set when the providers stopped early (hit or file cap): the page says so under the count.
    private(set) var truncation: SearchError.Limit?

    @ObservationIgnored let providers: [any SearchProvider]
    @ObservationIgnored private let scope: () -> (roots: [URL], files: FileTreeOptions)
    @ObservationIgnored private let debouncer = Debouncer(delay: .milliseconds(200))
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(providers: [any SearchProvider] = [AppSearch.builtin], scope: @escaping () -> (roots: [URL], files: FileTreeOptions)) {
        self.providers = providers
        self.scope = scope
    }

    /// The folders being searched, as the page names them ("MyBook"); "" with none. Reads the sidebar's state, so a view
    /// that shows it follows the workspace.
    var scopeTitle: String { SearchScope.title(of: scope().roots) }
    var hitCount: Int { groups.reduce(0) { $0 + $1.hits.count } }
    var isSearching: Bool { status == .searching }
    var hits: [SearchHit] { groups.flatMap(\.hits) }
    var selectedHit: SearchHit? { selection.flatMap { id in hits.first { $0.id == id } } }

    /// The badge of the provider that found `hit` ("内置").
    func badge(for hit: SearchHit) -> String { providers.first { $0.id == hit.source }?.badge ?? "" }

    func requestFocus() { focusTick += 1 }

    // MARK: Running

    private func queryChanged() {
        if currentQuery(files: FileTreeOptions()).isBlank {
            debouncer.cancel()
            clear()
        } else {
            debouncer.submit { [weak self] in self?.start() }
        }
    }

    /// Esc: forget the query and the results.
    func clearQuery() { query = "" }

    /// Starts over with the current query; also called when the scope or the file filter changed.
    func start() {
        debouncer.cancel()
        let (roots, files) = scope()
        let q = currentQuery(files: files)
        guard !q.isBlank else { clear(); return }
        cancelRunning()
        groups = []
        selection = nil
        truncation = nil
        guard !roots.isEmpty else { status = .noScope; return }
        status = .searching
        let generation = generation
        task = Task { [weak self] in await self?.run(q, roots: roots, generation: generation) }
    }

    private func clear() {
        cancelRunning()
        groups = []
        selection = nil
        truncation = nil
        status = .idle
    }

    private func cancelRunning() {
        // Cancelling the task ends the stream being read, which stops that provider's work (providers are shared by the
        // windows, so no `cancelAll()` here).
        task?.cancel()
        generation += 1
    }

    private func currentQuery(files: FileTreeOptions) -> SearchQuery { SearchQuery(text: query, isRegex: isRegex, files: files) }

    private func run(_ q: SearchQuery, roots: [URL], generation: Int) async {
        var buffer: [SearchHit] = []
        var lastFlush = ContinuousClock.now
        var remaining = q.limit
        var failure: String?
        var truncated: SearchError.Limit?

        func flush() {
            guard generation == self.generation, !buffer.isEmpty else { return }
            append(buffer, roots: roots)
            buffer = []
            lastFlush = .now
        }

        outer: for root in roots {
            for provider in providers {
                if Task.isCancelled { return }
                var sub = q
                sub.limit = max(remaining, 0)
                do {
                    guard case .ready = try await provider.prepare(workspace: root) else { continue }
                    for try await hit in provider.search(sub, in: root) {
                        buffer.append(hit)
                        remaining -= 1
                        if ContinuousClock.now - lastFlush > .milliseconds(60) { flush() }
                    }
                } catch SearchError.truncated(let limit) {
                    if case .hits = limit {
                        truncated = .hits(q.limit)  // the cap is for the whole search, not per folder
                        break outer
                    }
                    truncated = limit
                } catch let error as SearchError {
                    failure = error.errorDescription
                    break outer
                } catch {
                    if Task.isCancelled { return }
                    failure = error.localizedDescription
                    break outer
                }
            }
        }
        guard !Task.isCancelled, generation == self.generation else { return }
        flush()
        truncation = truncated
        status = failure.map(SearchStatus.failed) ?? .finished
        if failure == nil {
            let n = hitCount
            AccessibilityNotification.Announcement(n == 0 ? "没有匹配项" : "找到 \(n) 处匹配").post()
        }
    }

    private func append(_ hits: [SearchHit], roots: [URL]) {
        for hit in hits {
            if groups.last?.file.fileKey == hit.file.fileKey {
                groups[groups.count - 1].hits.append(hit)
            } else {
                groups.append(SearchGroup(file: hit.file, folder: Self.folder(of: hit.file, in: roots), hits: [hit]))
            }
        }
        if selection == nil { selection = groups.first?.hits.first?.id }
    }

    /// "chapters/part1" for `/root/chapters/part1/a.md`; "" for a file directly in the root, the full folder path when the
    /// file is in none of them.
    static func folder(of file: URL, in roots: [URL]) -> String {
        let dir = file.deletingLastPathComponent().fileKey
        for root in roots {
            let key = root.fileKey, prefix = key == "/" ? "/" : key + "/"
            if dir == key { return "" }
            if dir.hasPrefix(prefix) { return String(dir.dropFirst(prefix.count)) }
        }
        return dir
    }
}

/// The providers every window shares. Extensions add theirs here later; the core one is always there.
@MainActor
enum AppSearch {
    static let builtin = BuiltinSearchBackend()
}
