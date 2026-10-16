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
    /// The user stopped a (semantic) search that was still running.
    case cancelled
    /// The query itself is wrong (a bad regular expression).
    case failed(String)
}

/// Where and over which files a search looked: the results are stale when this is different now.
struct SearchScopeSnapshot: Equatable {
    let roots: [String]
    let files: FileTreeOptions
    /// The sources (an extension switched on or off answers differently).
    let providers: [String]
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
    /// Why an extension's provider did not answer (not installed, failed), shown under the status; the built-in search did.
    private(set) var notes: [String] = []
    /// The results come from a semantic search (Return or the sparkles button), not from the words typed.
    private(set) var isSemantic = false

    /// The extensions' providers first, the built-in search last (PLAN 4.12): for each folder the first one that is ready
    /// answers. Read on every search, so switching an extension on or off takes effect at once.
    @ObservationIgnored private let providerList: () -> [any SearchProvider]
    @ObservationIgnored private let scope: () -> (roots: [URL], files: FileTreeOptions)
    @ObservationIgnored private let debouncer = Debouncer(delay: .milliseconds(200))
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The scope the current results (or the running search) belong to.
    @ObservationIgnored private var searchedScope: SearchScopeSnapshot?

    init(providers: @escaping () -> [any SearchProvider] = { AppSearch.providers }, scope: @escaping () -> (roots: [URL], files: FileTreeOptions)) {
        providerList = providers
        self.scope = scope
    }

    var providers: [any SearchProvider] { providerList() }
    /// Changes when an extension adds or removes its provider: the page starts over then.
    var providerIDs: [String] { providers.map(\.id) }
    /// A provider can search by meaning: Return in the field and the sparkles button do that. Not with "All" file types,
    /// which only the built-in search covers.
    var supportsSemantic: Bool { canSearchSemantically(files: scope().files) }

    /// Regardless of the regular-expression switch, which only greys the sparkles button out.
    private func canSearchSemantically(files: FileTreeOptions) -> Bool {
        let semantic = SearchQuery(text: query, files: files, isSemantic: true)
        return providers.contains { $0.canRun(semantic) }
    }

    /// The folders being searched, as the page names them ("MyBook"); "" with none. Reads the sidebar's state, so a view
    /// that shows it follows the workspace.
    var scopeSnapshot: SearchScopeSnapshot {
        let (roots, files) = scope()
        return SearchScopeSnapshot(roots: roots.map(\.fileKey), files: files, providers: providerIDs)
    }

    /// The search page came back on screen: the folder or the file filter may have changed meanwhile (on the Files page).
    func revalidate() {
        if !currentQuery(files: FileTreeOptions()).isBlank, scopeSnapshot != searchedScope { start() }
    }

    var scopeTitle: String { SearchScope.title(of: scope().roots) }
    var hitCount: Int { groups.reduce(0) { $0 + $1.hits.count } }
    var isSearching: Bool { status == .searching }
    var hits: [SearchHit] { groups.flatMap(\.hits) }
    var selectedHit: SearchHit? { selection.flatMap { id in hits.first { $0.id == id } } }

    /// The badge of the provider that found `hit` ("Built-in").
    func badge(for hit: SearchHit) -> String { providers.first { $0.id == hit.source }?.badge ?? "" }

    func requestFocus() { focusTick += 1 }

    // MARK: Running

    private func queryChanged() {
        if currentQuery(files: FileTreeOptions()).isBlank {
            cancelDebounce()
            clear()
        } else {
            // qmd starts a process per search: typing waits a little longer while an extension provider is on.
            debouncer.submit(after: providers.count > 1 ? .milliseconds(250) : nil) { [weak self] in self?.start() }
        }
    }

    private func cancelDebounce() { debouncer.cancel() }

    /// The search page came on screen: extension providers may look for their tool and ask their questions now (PLAN 4.12:
    /// qmd's detection, consent and collection registration happen on the first opening, not at launch).
    func prepareProviders() {
        let roots = scope().roots
        let providers = providers
        guard !roots.isEmpty else { return }
        Task { [weak self] in
            var reasons: [String] = []
            for provider in providers {
                for root in roots {
                    if case .unavailable(let reason)? = try? await provider.prepare(workspace: root), !reason.isEmpty { reasons.append(reason) }
                }
            }
            guard let self, self.status == .idle || self.status == .noScope else { return }
            self.notes = Self.unique(reasons)
        }
    }

    /// Return in the field (or the sparkles button) while a provider can search by meaning: the same text, semantically.
    func startSemantic() { start(semantic: true) }

    /// Stops a running search and keeps what was found.
    func stopSearching() {
        guard status == .searching else { return }
        cancelRunning()
        status = .cancelled
    }

    private static func unique(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    /// Esc: forget the query and the results.
    func clearQuery() { query = "" }

    /// Starts over with the current query; also called when the scope or the file filter changed.
    func start() { start(semantic: false) }

    private func start(semantic: Bool) {
        cancelDebounce()
        let (roots, files) = scope()
        var q = currentQuery(files: files)
        q.isSemantic = semantic && !q.isRegex && canSearchSemantically(files: files)
        isSemantic = q.isSemantic
        searchedScope = SearchScopeSnapshot(roots: roots.map(\.fileKey), files: files, providers: providerIDs)
        guard !q.isBlank else { clear(); return }
        cancelRunning()
        groups = []
        selection = nil
        truncation = nil
        notes = []
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
        notes = []
        isSemantic = false
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
        var reasons: [String] = []

        func flush() {
            guard generation == self.generation, !buffer.isEmpty else { return }
            append(buffer, roots: roots)
            buffer = []
            lastFlush = .now
        }

        outer: for root in roots {
            let providers = providers
            for (index, provider) in providers.enumerated() {
                if Task.isCancelled { return }
                // Only the built-in search does regular expressions and "All" file types (an extension's index has its own
                // set of files); a semantic search goes to a provider that can do it, or nowhere.
                if !provider.canRun(q) { continue }
                var sub = q
                sub.limit = max(remaining, 0)
                var found = 0
                do {
                    if case .unavailable(let reason) = try await provider.prepare(workspace: root) {
                        if !reason.isEmpty { reasons.append(reason) }
                        continue
                    }
                    for try await hit in provider.search(sub, in: root) {
                        buffer.append(hit)
                        remaining -= 1
                        found += 1
                        if ContinuousClock.now - lastFlush > .milliseconds(60) { flush() }
                    }
                    break  // this folder is answered: the providers after it are fallbacks
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
                    // A search failed before finding anything and a provider after it can take the query (the built-in one
                    // for an extension's keyword search): that one answers instead.
                    if found == 0, providers[(index + 1)...].contains(where: { $0.canRun(q) }) {
                        reasons.append(error.localizedDescription)
                        continue
                    }
                    failure = error.localizedDescription
                    break outer
                }
            }
        }
        guard !Task.isCancelled, generation == self.generation else { return }
        flush()
        notes = Self.unique(reasons)
        truncation = truncated
        status = failure.map(SearchStatus.failed) ?? .finished
        if failure == nil {
            let n = hitCount
            AccessibilityNotification.Announcement(n == 0 ? String(localized: "No matches") : String(localized: "Found \(n) matches")).post()
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

/// The providers every window shares: those of the extensions that are on, then the core one, which is always there.
@MainActor
enum AppSearch {
    static let builtin = BuiltinSearchBackend()
    static var providers: [any SearchProvider] { AppExtensions.host.searchProviders + [builtin] }
}
