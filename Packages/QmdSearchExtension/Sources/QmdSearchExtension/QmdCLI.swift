import Darwin
import ExtensionAPI
import Foundation
import os

let qmdLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "qmd")

/// What one qmd run left behind.
struct QmdOutput: Sendable, Equatable {
    var stdout: Data
    var stderr: String
    var status: Int32
}

enum QmdError: Error, Equatable, LocalizedError {
    case timedOut(seconds: Int64)
    /// qmd exited non-zero; `message` is the gist of its stderr.
    case failed(status: Int32, message: String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): L10n.timedOut(seconds)
        case .failed(_, let message): message
        case .badOutput: L10n.badOutput
        }
    }
}

/// Starts qmd: one binary, the login-shell environment (PLAN 4.16), `/` as the working directory. `/` because qmd walks up
/// from its working directory looking for a project-local `.qmd/index.yml` (which would switch it to another index) and
/// prints `--full-path` results under it as `./…`.
///
/// stderr is kept (the `ProcessSpawner` contract only returns stdout): the run goes through `/bin/sh -c 'exec "$@" 2>"$0"'`,
/// which replaces itself with qmd in the same process group, so cancelling still kills qmd and whatever it started. The
/// arguments travel as arguments, never through the shell's parser.
struct QmdRunner: Sendable {
    let executable: String
    let environment: [String: String]
    let makeSpawner: @Sendable ([String: String]) -> any ProcessSpawner

    static let shell = "/bin/sh"
    static let shellScript = #"exec "$@" 2>"$0""#
    static let workingDirectory = "/"
    // lazy: the last 16 KB of stderr is kept for the log and the error text; qmd's errors are a line or a stack trace
    static let stderrLimit = 16 * 1024

    static let utilityPrefix = ["/usr/sbin/taskpolicy", "-c", "utility"]

    /// The qmd arguments of a spawn this runner made (tests' fakes use it), nil for anything else.
    static func qmdArguments(executable: String, arguments: [String]) -> [String]? {
        guard executable == shell, arguments.count >= 4, arguments[0] == "-c", arguments[1] == shellScript else { return nil }
        let rest = arguments.dropFirst(3)
        return Array((rest.starts(with: utilityPrefix) ? rest.dropFirst(utilityPrefix.count) : rest).dropFirst())
    }

    /// The stderr file of a spawn this runner made.
    static func stderrPath(arguments: [String]) -> String? { arguments.count >= 3 ? arguments[2] : nil }

    /// - Parameter utility: run clamped to utility QoS (`taskpolicy -c utility`), for the heavy background `qmd embed`.
    func run(_ arguments: [String], timeout: Duration, utility: Bool = false) async throws -> QmdOutput {
        let errorFile = FileManager.default.temporaryDirectory.appending(path: "macdown2-qmd-\(UUID().uuidString).err").path
        defer { unlink(errorFile) }
        let spawner = makeSpawner(environment)
        let argv = ["-c", Self.shellScript, errorFile] + (utility ? Self.utilityPrefix : []) + [executable] + arguments
        let output: ProcessOutput = try await withThrowingTaskGroup(of: ProcessOutput?.self) { group in
            group.addTask { try await spawner.run(executable: Self.shell, arguments: argv, directory: Self.workingDirectory) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }  // kills qmd's process group when the timeout (or the caller's cancel) wins
            guard let first = try await group.next(), let output = first else { throw QmdError.timedOut(seconds: timeout.components.seconds) }
            return output
        }
        let stderr = Self.readTail(errorFile)
        let command = arguments.first ?? ""
        if !stderr.isEmpty { qmdLog.info("qmd \(command, privacy: .public) stderr: \(stderr, privacy: .public)") }
        guard output.status == 0 else {
            qmdLog.error("qmd \(command, privacy: .public) exited with status \(output.status)")
            throw QmdError.failed(status: output.status, message: Self.gist(of: stderr, status: output.status))
        }
        return QmdOutput(stdout: output.stdout, stderr: stderr, status: output.status)
    }

    private static func readTail(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(stderrLimit) ? size - UInt64(stderrLimit) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line that says what went wrong: Node's `Error: …`, else the last line qmd wrote.
    static func gist(of stderr: String, status: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { $0.hasPrefix("Error:") } ?? lines.last { !$0.hasPrefix("at ") && !$0.hasPrefix("Node.js") } ?? ""
        let text = line.isEmpty ? L10n.exitStatus(status) : line
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

// MARK: Parsing qmd's output (fixed against qmd 2.8.3; see Tests/…/Fixtures)

enum QmdParse {
    /// qmd 2.8.3 is the version these parsers were checked against; older ones are treated as not installed.
    // lazy: one floor for everything, the one version verified; upgrade: probe the features (json `line`, `collection exclude`) instead
    static let minimumVersion = [2, 8, 0]

    /// `qmd 2.8.3 (facd35e)` → [2, 8, 3].
    static func version(_ text: String) -> [Int]? {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/) else { return nil }
        return [Int(match.1), Int(match.2), Int(match.3)].compactMap(\.self)
    }

    static func isSupported(_ version: [Int]) -> Bool { version.lexicographicallyPrecedes(minimumVersion) == false }

    /// Collection names from `qmd collection list` (no `--format json` there: it is ignored and the text comes back).
    /// A collection is a line `name (qmd://name/)`, `[excluded]` after it when it is left out of default queries; its
    /// details are indented below.
    static func collectionNames(fromList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let first = line.first, !first.isWhitespace, let r = line.range(of: " (qmd://") else { return nil }
            let name = String(line[..<r.lowerBound])
            return line[r.upperBound...].hasPrefix(name + "/)") ? name : nil
        }
    }

    /// `qmd collection show <name>`: the folder (only shown here, not by `list`), the mask, and whether `qmd update` runs a
    /// command for it first (`Update:`).
    static func collection(named name: String, fromShow text: String) -> QmdCollection? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.first?.isWhitespace == true, let colon = trimmed.firstIndex(of: ":") else { continue }
            fields[String(trimmed[..<colon])] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let path = fields["Path"], path.hasPrefix("/") else { return nil }
        return QmdCollection(
            name: name, path: path, pattern: fields["Pattern"] ?? "", includedByDefault: fields["Include"].map { !$0.hasPrefix("no") } ?? true,
            hasUpdateCommand: !(fields["Update"] ?? "").isEmpty)
    }

    /// One result of `qmd search|query --format json --full-path`. Fields seen in 2.8.3: `score` (rounded to 2 places; 0
    /// is common for BM25 on small sets), `file` (absolute realpath, or `./…` under the working directory, or `qmd://…` with
    /// a `docid` when the file is gone), `line` (1-based, the snippet's best line), `title`, `snippet` (a `@@ -start,count
    /// @@ (n before, m after)` header, then whole lines starting at `start`), `context`, `docid`. Unknown fields are ignored.
    struct Result: Decodable, Equatable, Sendable {
        var file: String
        var line: Int?
        var title: String?
        var score: Double?
        var snippet: String?
    }

    static func results(_ data: Data) throws -> [Result] {
        do {
            return try JSONDecoder().decode([Result].self, from: data)
        } catch {
            throw QmdError.badOutput
        }
    }

    /// The line `line` of a snippet (the header says which line it starts at); nil when it is not in there.
    static func snippetLine(_ snippet: String, line: Int) -> String? {
        var lines = snippet.components(separatedBy: "\n")
        guard let header = lines.first, let match = header.firstMatch(of: /^@@ -(\d+)/), let start = Int(match.1) else { return nil }
        lines.removeFirst()
        let index = line - start
        return lines.indices.contains(index) ? lines[index] : nil
    }
}

/// A qmd collection as `collection show` describes it.
struct QmdCollection: Sendable, Equatable {
    var name: String
    /// As qmd stored it (a realpath when qmd added it).
    var path: String
    var pattern: String
    var includedByDefault: Bool
    /// `qmd update` runs a shell command (`git pull`, …) for it before re-indexing.
    var hasUpdateCommand: Bool
}

/// realpath(3): what qmd stores and reports (`/private/tmp/…`, symlinks resolved). The path itself when it does not exist.
func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return path }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
