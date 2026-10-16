import Darwin
import ExtensionAPI
import Foundation
import Observation
import Synchronization
import WorkspaceKit

/// What the search page shows about the semantic setup: the engine publishes, the page reads it while it is drawn (observable).
@MainActor @Observable
final class QmdSetupBoard {
    /// Workspace folder (`fileKey`) → the collection that serves it.
    private(set) var collections: [String: String] = [:]
    /// Collection → its setup; absent = nothing to wait for.
    private(set) var states: [String: SemanticSetup] = [:]
    @ObservationIgnored private var version = 0

    nonisolated init() {}

    /// A snapshot from the engine; one older than the last applied (the hops to the main actor may overtake) is dropped.
    func apply(version: Int, collections: [String: String], states: [String: SemanticSetup]) {
        guard version > self.version else { return }
        self.version = version
        if self.collections != collections { self.collections = collections }
        if self.states != states { self.states = states }
    }

    func collection(for workspace: URL) -> String? { collections[workspace.fileKey] }

    /// `.ready` for a folder that is not prepared yet: the search itself prepares it, and refuses while its setup runs.
    func state(for workspace: URL) -> SemanticSetup {
        collection(for: workspace).flatMap { states[$0] } ?? .ready
    }
}

/// Cancels the tasks that run qmd processes from any thread, at once: the app's quit cannot wait for the engine's actor.
final class LiveTasks: Sendable {
    private let tasks = Mutex<[UUID: @Sendable () -> Void]>([:])

    func insert(_ id: UUID, cancel: @escaping @Sendable () -> Void) { tasks.withLock { $0[id] = cancel } }
    func remove(_ id: UUID) { _ = tasks.withLock { $0.removeValue(forKey: id) } }

    /// Cancelling a task kills its qmd's process group in the cancellation handler, before this returns.
    func cancelAll() {
        for cancel in tasks.withLock({ Array($0.values) }) { cancel() }
    }
}

/// Where qmd keeps its files, and what its model cache holds (read straight from the disk, no qmd process).
enum QmdFiles {
    /// `$XDG_CACHE_HOME/qmd` (qmd ignores an empty one), else `~/.cache/qmd`: the index and the `models` folder.
    static func cacheDirectory(_ environment: [String: String]) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return (environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.cache") + "/qmd"
    }

    /// `$QMD_CONFIG_DIR`, else `$XDG_CONFIG_HOME/qmd`, else `~/.config/qmd`: where `index.yml` names the models.
    static func configDirectory(_ environment: [String: String]) -> String {
        if let dir = environment["QMD_CONFIG_DIR"], !dir.isEmpty { return dir }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return (environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config") + "/qmd"
    }

    /// The models being downloaded into `models`: node-llama-cpp writes `<file>.ipull`, created at its full size and filled in
    /// as it arrives, so the blocks on disk are what has arrived. nil when nothing is downloading.
    static func downloads(in models: String) -> (done: Int64, total: Int64)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: models) else { return nil }
        var done: Int64 = 0, total: Int64 = 0, any = false
        for name in names where name.hasSuffix(".ipull") {
            var info = stat()
            guard lstat(models + "/" + name, &info) == 0 else { continue }
            any = true
            total += Int64(info.st_size)
            done += min(Int64(info.st_blocks) * 512, Int64(info.st_size))
        }
        return any ? (done, total) : nil
    }

    /// The model URIs in qmd's `index.yml` (`models:` → `embed:`, `generate:`, `rerank:`), as qmd writes them.
    static func configuredModels(_ yaml: String) -> [String: String] {
        var models: [String: String] = [:]
        var inModels = false
        for line in yaml.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            if !first.isWhitespace {
                inModels = line.trimmingCharacters(in: .whitespaces) == "models:"
                continue
            }
            guard inModels, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { models[key] = value }
        }
        return models
    }

    /// The models semantic search needs are in qmd's cache: the embedding and query-expansion models, and the reranker when
    /// reranking is on. Matched as `qmd doctor` does: a `.gguf` in `models` whose name holds the `hf:` URI's file name, or the
    /// file itself for a path. Without a `models:` section, any `.gguf` counts.
    // lazy: qmd's environment overrides (QMD_EMBED_MODEL, …) are not read; qmd writes the models into index.yml, which wins over them
    static func modelsPresent(cache: String, config: String, rerank: Bool) -> Bool {
        let models = cache + "/models"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: models)) ?? []).filter { $0.hasSuffix(".gguf") }
        let configured = configuredModels((try? String(contentsOfFile: config + "/index.yml", encoding: .utf8)) ?? "")
        let needed = (rerank ? ["embed", "generate", "rerank"] : ["embed", "generate"]).compactMap { configured[$0] }
        guard !needed.isEmpty else { return !files.isEmpty }
        return needed.allSatisfy { uri in
            if uri.hasPrefix("hf:") {
                guard let file = uri.split(separator: "/").last, !file.isEmpty else { return false }
                return files.contains { $0.contains(file) }
            }
            return FileManager.default.fileExists(atPath: (uri as NSString).expandingTildeInPath)
        }
    }
}
