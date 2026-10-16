import Darwin
import ExtensionAPI
import Foundation

/// One `quarto preview` for one document (PLAN 4.6.2):
///
///     quarto preview <abs.qmd> --no-browser --host 127.0.0.1 --port <p> --render html --log <tmp>/quarto-<uuid>.log --log-format json-stream
///
/// run in the document's folder with the full login-shell environment (that is how conda/venv Python and R are found). `<p>` is
/// only a suggestion (a port that was free a moment ago); Quarto may take another, so the page's URL is read from what it prints
/// ("Browse at http://localhost:4321/"). No URL within `timeout` = a failed start. `stop()` SIGTERMs the process group and
/// SIGKILLs it 3 s later if it is still there.
actor QuartoPreviewProcess {
    enum Event: Sendable, Equatable {
        /// A render after the first one started (the file was saved).
        case rendering
        case rendered(Date)
        /// A render failed; the server goes on with the last good output.
        case renderFailed
        /// The process is gone by itself (not by `stop`), with this status.
        case exited(Int32)
    }

    enum StartError: Error, Equatable {
        case launch(String)
        case timedOut
        case exited(Int32)
        case stopped
    }

    /// Events after a successful start, in order; finishes when the process is gone.
    nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private let quarto: String
    private let document: URL
    private let environment: [String: String]
    private let timeout: Duration
    private let stopGrace: Duration
    nonisolated let logFile: URL
    /// The last lines Quarto printed (ANSI escapes removed), for the log when its JSON log has no error entries.
    nonisolated let console = ConsoleTail()

    private var child: QuartoChild?
    private var partialLine = ""
    private var url: URL?
    private var urlWaiter: CheckedContinuation<URL, any Error>?
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopping = false
    /// The error entries of the log, read when the process went away (the file is deleted then).
    private(set) var finalLogErrors: [String]?

    init(quarto: String, document: URL, environment: [String: String], timeout: Duration = .seconds(30), stopGrace: Duration = .seconds(3), temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.quarto = quarto
        self.document = document
        self.environment = environment
        self.timeout = timeout
        self.stopGrace = stopGrace
        logFile = temporaryDirectory.appending(path: "quarto-\(UUID().uuidString).log")
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    /// The arguments after `quarto` (`port` nil: Quarto picks one).
    static func arguments(document: URL, port: Int?, logFile: URL) -> [String] {
        ["preview", document.path, "--no-browser", "--host", "127.0.0.1"] + (port.map { ["--port", String($0)] } ?? [])
            + ["--render", "html", "--log", logFile.path, "--log-format", "json-stream"]
    }

    /// Starts Quarto and returns the page's URL once it serves one.
    func start() async throws -> URL {
        precondition(child == nil && exitStatus == nil, "a QuartoPreviewProcess starts once")
        let (raw, rawSink) = AsyncStream.makeStream(of: ChildEvent.self)
        do {
            child = try QuartoChild.launch(
                executable: quarto, arguments: Self.arguments(document: document, port: Self.freePort(), logFile: logFile),
                directory: document.deletingLastPathComponent().path, environment: environment, logFile: logFile,
                onOutput: { rawSink.yield(.output($0)) },
                onExit: { exit in
                    rawSink.yield(.exit(exit.status, exit.logErrors))
                    rawSink.finish()
                }
            )
        } catch {
            eventSink.finish()
            // The bare reason ("No such file or directory"): the message around it already says Quarto could not start.
            if case .launchFailed(let code)? = error as? ProcessSpawnError { throw StartError.launch(String(cString: strerror(code))) }
            throw StartError.launch(error.localizedDescription)
        }
        // One consumer, so output and the exit are handled in the order they happened.
        Task { for await event in raw { self.handle(event) } }
        let timeout = timeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.failStart(.timedOut) }
        }
        defer { timer.cancel() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                if let url { continuation.resume(returning: url) } else { urlWaiter = continuation }
            }
        } catch let error as StartError {
            if error == .timedOut { await stop() }
            throw error
        }
    }

    /// SIGTERM to the group, SIGKILL after the grace period; returns once the process is gone. Idempotent.
    func stop() async {
        stopping = true
        failStart(.stopped)
        guard let child, exitStatus == nil else { return }
        child.signal(SIGTERM)
        let grace = stopGrace
        let killer = Task {
            try? await Task.sleep(for: grace)
            if !Task.isCancelled { child.signal(SIGKILL) }
        }
        await waitForExit()
        killer.cancel()
    }

    private func waitForExit() async {
        guard exitStatus == nil else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// The log's error entries (live: read from the file; afterwards: what was read before it was deleted), else the end of the console.
    func logText() -> String { Self.logText(errors: finalLogErrors ?? QuartoLog.errors(in: logFile), console: console) }

    /// What "View Log" shows: the log's error entries, else the end of the console, else that there is nothing yet.
    nonisolated static func logText(errors: [String], console: ConsoleTail) -> String {
        let lines = errors.isEmpty ? console.lines : errors
        return lines.isEmpty ? L10n.emptyLog : lines.joined(separator: "\n")
    }

    // MARK: Output

    private enum ChildEvent: Sendable {
        case output(Data)
        case exit(Int32, [String])
    }

    private func handle(_ event: ChildEvent) {
        switch event {
        case .output(let data):
            partialLine += String(decoding: data, as: UTF8.self)
            var lines = partialLine.components(separatedBy: "\n")
            partialLine = lines.removeLast()
            for line in lines { handle(line: QuartoConsole.clean(line)) }
        case .exit(let status, let errors):
            if !partialLine.isEmpty { handle(line: QuartoConsole.clean(partialLine)) }
            partialLine = ""
            finalLogErrors = errors
            exitStatus = status
            failStart(.exited(status))
            if !stopping { eventSink.yield(.exited(status)) }
            eventSink.finish()
            exitWaiters.forEach { $0.resume() }
            exitWaiters = []
        }
    }

    private func handle(line: String) {
        console.append(line)
        if url == nil {
            if let found = QuartoConsole.pageURL(in: line) {
                url = found
                eventSink.yield(.rendered(Date()))
                urlWaiter?.resume(returning: found)
                urlWaiter = nil
            }
            return
        }
        if let event = QuartoConsole.event(for: line) { eventSink.yield(event) }
    }

    private func failStart(_ error: StartError) {
        urlWaiter?.resume(throwing: error)
        urlWaiter = nil
    }

    /// A TCP port on 127.0.0.1 that was free just now (the kernel's pick for port 0); nil when none could be had.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The last lines a process printed, readable from any thread.
final class ConsoleTail: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    // lazy: 200 lines kept; the JSON log is what "View Log" shows first
    private let limit = 200

    func append(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lock.withLock {
            stored.append(line)
            if stored.count > limit { stored.removeFirst(stored.count - limit) }
        }
    }

    var lines: [String] { lock.withLock { stored } }
}

/// What `quarto preview` prints (on stderr, in colour), read line by line.
enum QuartoConsole {
    private static let escape = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    /// `line` without ANSI colour codes and the trailing carriage return.
    static func clean(_ line: String) -> String {
        let stripped = escape.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    /// The page from "Browse at http://localhost:4321/" (or the server's "Listening on http://127.0.0.1:4321/"). Only a loopback
    /// http URL counts; "localhost" becomes 127.0.0.1, the address Quarto was told to listen on (WebKit would try ::1 first).
    static func pageURL(in line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let rest: Substring
        if trimmed.hasPrefix("Browse at") {
            rest = trimmed.dropFirst("Browse at".count)
        } else if trimmed.hasPrefix("Listening on") {
            rest = trimmed.dropFirst("Listening on".count)
        } else {
            return nil
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: text), components.scheme == "http", let host = components.host, components.port != nil else { return nil }
        switch host.lowercased() {
        case "localhost": components.host = "127.0.0.1"
        case "127.0.0.1": break
        default: return nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// What a line printed while the page is up says about the render, nil when it says nothing.
    // lazy: matches Quarto's English console lines; the JSON log has no structured "render started/finished" event to read instead
    static func event(for line: String) -> QuartoPreviewProcess.Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("Output created:") { return .rendered(Date()) }
        if trimmed.hasPrefix("ERROR") { return .renderFailed }
        for quiet in ["Watching files for changes", "Browse at", "Listening on", "GET:", "WARNING", "WARN"] where trimmed.hasPrefix(quiet) { return nil }
        return .rendering
    }
}
