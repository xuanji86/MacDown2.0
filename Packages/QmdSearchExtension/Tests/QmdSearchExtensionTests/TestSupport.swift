import ExtensionAPI
import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

/// A pretend qmd: every spawn the runner makes is decoded back to qmd's arguments, recorded, and answered by `answer`.
final class FakeQmd: ProcessSpawner, @unchecked Sendable {
    struct Reply: Sendable {
        var stdout = ""
        var stderr = ""
        var status: Int32 = 0
    }

    private let lock = NSLock()
    private var calls: [[String]] = []
    private var environments: [[String: String]] = []
    var answer: @Sendable ([String]) -> Reply

    init(answer: @escaping @Sendable ([String]) -> Reply = { _ in Reply() }) { self.answer = answer }

    var spawns: Int { lock.withLock { calls.count } }
    var commands: [[String]] { lock.withLock { calls } }
    var lastEnvironment: [String: String]? { lock.withLock { environments.last } }

    func makeSpawner(_ environment: [String: String]) -> any ProcessSpawner {
        lock.withLock { environments.append(environment) }
        return self
    }

    func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        let qmd = QmdRunner.qmdArguments(executable: executable, arguments: arguments) ?? [executable] + arguments
        #expect(directory == "/")
        lock.withLock { calls.append(qmd) }
        let reply = answer(qmd)
        if !reply.stderr.isEmpty, let path = QmdRunner.stderrPath(arguments: arguments) { try Data(reply.stderr.utf8).write(to: URL(filePath: path)) }
        return ProcessOutput(stdout: Data(reply.stdout.utf8), status: reply.status)
    }
}

/// A login-shell environment that counts how often it was read. `PATH` holds a folder with an executable called `qmd`.
final class FakeEnvironment: ToolEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let bin: URL
    let extra: [String: String]

    init(extra: [String: String] = [:], qmdScript: String = "#!/bin/sh\nexit 0\n") throws {
        bin = FileManager.default.temporaryDirectory.appending(path: "qmd-bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appending(path: "qmd")
        try Data(qmdScript.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        self.extra = extra
    }

    var reads: Int { lock.withLock { n } }

    func snapshot() async -> ToolEnvironmentSnapshot {
        lock.withLock { n += 1 }
        var environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        environment.merge(extra) { $1 }
        return ToolEnvironmentSnapshot(environment: environment, source: .loginShell(path: "/bin/zsh"), seconds: 0)
    }

    deinit { try? FileManager.default.removeItem(at: bin) }
}

/// Answers for a qmd that knows `collections` (name → folder).
func standardAnswers(collections: [(name: String, path: String, update: String?)], search: String = "[]", version: String = "qmd 2.8.3 (facd35e)") -> @Sendable ([String]) -> FakeQmd.Reply {
    let collections = collections
    return { args in
        switch (args.first, args.dropFirst().first) {
        case ("--version", _): return .init(stdout: version + "\n")
        case ("collection", "list"):
            guard !collections.isEmpty else { return .init(stdout: "No collections found. Run 'qmd collection add .' to create one.\n") }
            return .init(stdout: "Collections (\(collections.count)):\n\n" + collections.map { "\($0.name) (qmd://\($0.name)/)\n  Pattern:  **/*.md\n  Files:    1\n  Updated:  1m ago\n\n" }.joined())
        case ("collection", "show"):
            guard let c = collections.first(where: { $0.name == args[2] }) else { return .init(stderr: "Collection not found: \(args[2])", status: 1) }
            return .init(stdout: "Collection: \(c.name)\n  Path:     \(c.path)\n  Pattern:  **/*.md\n  Include:  yes (default)\n" + (c.update.map { "  Update:   \($0)\n" } ?? ""))
        case ("search", _), ("query", _): return .init(stdout: search)
        default: return .init()
        }
    }
}

final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    var values: [Value] { lock.withLock { items } }
    func add(_ value: Value) { lock.withLock { items.append(value) } }
}

/// A provider wired to fakes; `consent` answers the registration question.
func makeProvider(
    qmd: FakeQmd, environment: FakeEnvironment, options: QmdOptions = QmdOptions(), consent: QmdConsentAnswer = .register,
    asked: Recorder<QmdConsentRequest> = Recorder(), declined: Recorder<String> = Recorder(), updateInterval: Duration = .seconds(60)
) -> QmdSearchProvider {
    let options = options
    return QmdSearchProvider(dependencies: QmdEngine.Dependencies(
        environment: environment,
        makeSpawner: { qmd.makeSpawner($0) },
        options: { options },
        consent: { asked.add($0); return consent },
        decline: { declined.add($0) },
        updateInterval: updateInterval,
        watchFolders: false
    ), semantic: options.semantic)
}

func temporaryFolder(_ name: String = "ws") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "qmd-tests-\(UUID().uuidString)/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func collect(_ stream: AsyncThrowingStream<SearchHit, any Error>) async throws -> [SearchHit] {
    var hits: [SearchHit] = []
    for try await hit in stream { hits.append(hit) }
    return hits
}
