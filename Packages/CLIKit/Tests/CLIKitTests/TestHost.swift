import Foundation
@testable import CLIKit

/// A `CLIHost` that records what the command prints and launches, over a scratch directory that stands in for the cwd and the home.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = "", _err = "", _launches: [[String]] = []
    var out: String { lock.withLock { _out } }
    var err: String { lock.withLock { _err } }
    var launches: [[String]] { lock.withLock { _launches } }
    func out(_ s: String) { lock.withLock { _out += s } }
    func err(_ s: String) { lock.withLock { _err += s } }
    func launch(_ args: [String]) { lock.withLock { _launches.append(args) } }
}

struct Scratch {
    let root: URL
    let recorder = Recorder()

    init() throws {
        // Resolved, so paths compare equal to what the CLI prints (/var vs /private/var).
        let dir = FileManager.default.temporaryDirectory.appending(path: "macdown2-cli-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.resolvingSymlinksInPath()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ name: String, _ text: String = "# hi\n") throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// cwd = root, home = root/home, stdin = `stdin` (a terminal when nil), launches recorded (status `launchStatus`).
    func host(stdin: String? = nil, environment: [String: String] = [:], executable: URL? = nil, defaults: UserDefaults? = nil,
              launchStatus: Int32 = 0, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CLIHost {
        let recorder = recorder
        nonisolated(unsafe) let defaults = defaults  // UserDefaults is thread-safe; the SDK just does not say Sendable
        return CLIHost(
            currentDirectory: root, environment: environment, home: root.appending(path: "home"), executable: executable,
            stdinIsTTY: stdin == nil, readStdin: { Data((stdin ?? "").utf8) },
            out: { recorder.out($0) }, err: { recorder.err($0) }, now: { now }, timeZone: TimeZone(identifier: "UTC")!,
            appDefaults: { defaults }, launch: { recorder.launch($0); return launchStatus }
        )
    }

    /// An empty preferences domain, so a developer's real MacDown2.0 settings cannot change a test.
    static func emptyDefaults() -> UserDefaults {
        let name = "macdown2-cli-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
