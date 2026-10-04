import Foundation

/// A throwaway directory under the system temp folder, removed on `cleanUp()` (or when the process exits).
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "WorkspaceKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> URL {
        let target = url.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let target = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

extension TempDir {
    /// The big-directory fixture: 5,000 `note-<i>.md` files and 50 `folder-<i>` folders (5,050 entries); `body` is a file's text.
    func bigDirectory(body: (Int) -> String = { _ in "" }) throws {
        for i in 0..<5000 { FileManager.default.createFile(atPath: url.appending(path: "note-\(i).md").path, contents: Data(body(i).utf8)) }
        for i in 0..<50 { try dir("folder-\(i)") }
    }
}

/// Thread-safe collector for callbacks that arrive on a background queue.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Polls `condition` until it holds or `seconds` pass.
func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
