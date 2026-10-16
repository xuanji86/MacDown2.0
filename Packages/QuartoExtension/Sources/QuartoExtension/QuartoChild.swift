import AppKit
import Darwin
import ExtensionAPI
import Foundation

/// A long-running child (`quarto preview`) in its own process group, stdout and stderr into one pipe. `quarto` is a bash script
/// that starts Deno without `exec`, and Deno starts pandoc / Jupyter / R: signals go to the whole group, never to one pid.
///
/// Output and the exit arrive on one serial queue, in order. On the exit the rest of the group gets up to 3 s, then is SIGKILLed
/// (orphans the script left behind), what is still in the pipe is read, the log file is read and deleted, and only then is the leader reaped: until that point its
/// zombie keeps the pid (and so the group id) from being reused, which makes `signal` safe to call at any time.
///
/// Every live child is in `QuartoChild.live`; the app's quit (`willTerminateNotification`, `atexit` as the last resort) stops them all.
final class QuartoChild: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var reaped = false
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// The exit was handled; only touched on `queue`.
    private var finished = false

    /// What the exit handler reports: the status (128 + signal when killed) and the log's error entries, read before it was deleted.
    typealias Exit = (status: Int32, logErrors: [String])

    private init(pid: pid_t, queue: DispatchQueue) {
        self.pid = pid
        self.queue = queue
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [pid_t: QuartoChild] = [:]
    nonisolated(unsafe) private static var quitHooksInstalled = false

    /// `logFile` is deleted once the child is gone (or here, when the launch fails).
    static func launch(
        executable: String, arguments: [String], directory: String, environment: [String: String], logFile: URL?,
        onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Exit) -> Void
    ) throws -> QuartoChild {
        installQuitHooks()
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessSpawnError.launchFailed(errno: errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        // Registered under the lock together with the spawn, so a quit in between cannot miss it.
        registryLock.lock()
        let spawned = Result {
            try SystemProcessSpawner.spawnInNewGroup(
                executable: executable, arguments: arguments, directory: directory, environment: environment, stdout: writeEnd, stderr: writeEnd)
        }
        close(writeEnd)
        let pid: pid_t
        do {
            pid = try spawned.get()
        } catch {
            registryLock.unlock()
            close(readEnd)
            if let logFile { try? FileManager.default.removeItem(at: logFile) }
            throw error
        }
        let child = QuartoChild(pid: pid, queue: DispatchQueue(label: "quarto.child.\(pid)"))
        live[pid] = child
        registryLock.unlock()

        let read = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: child.queue)
        read.setEventHandler { if let data = Self.drain(readEnd) { onOutput(data) } }
        read.setCancelHandler { close(readEnd) }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: child.queue)
        let finish: @Sendable () -> Void = { [child] in
            guard !child.finished else { return }
            child.finished = true
            // The script is gone (bash dies of a SIGTERM at once). The rest of its group gets the same grace before a SIGKILL: Deno
            // removes its temp files on the way out. The zombie leader keeps the group id reserved meanwhile.
            let deadline = Date().addingTimeInterval(QuartoChild.stragglerGrace)
            while Self.groupHasOthers(pid), Date() < deadline { usleep(50_000) }
            kill(-pid, SIGKILL)
            if let data = Self.drain(readEnd) { onOutput(data) }
            child.readSource?.cancel()
            child.exitSource?.cancel()
            let errors = logFile.map(QuartoLog.errors(in:)) ?? []
            if let logFile { try? FileManager.default.removeItem(at: logFile) }
            var status: Int32 = 0
            child.lock.withLock {
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                child.reaped = true
            }
            registryLock.withLock { _ = live.removeValue(forKey: pid) }
            onExit((SystemProcessSpawner.exitStatus(status), errors))
        }
        exit.setEventHandler(handler: finish)
        child.readSource = read
        child.exitSource = exit
        read.resume()
        exit.resume()
        // A child that was already gone when the source was armed may never be reported by it: look once (`WNOWAIT` leaves the zombie).
        child.queue.async {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { finish() }
        }
        return child
    }

    /// Sends `signal` to the child's process group; nothing once the child has been reaped.
    func signal(_ signal: Int32) {
        lock.withLock {
            if !reaped { kill(-pid, signal) }
        }
    }

    var hasExited: Bool { lock.withLock { reaped } }

    /// How long the rest of the group may outlive the script before it is SIGKILLed (the same 3 s as `stop`).
    static let stragglerGrace: TimeInterval = 3

    /// Something besides the (zombie) leader is still in the group `pgid`.
    private static func groupHasOthers(_ pgid: pid_t) -> Bool {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = Int(proc_listpgrppids(pgid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return count > 0 && pids.prefix(min(count, pids.count)).contains { $0 != 0 && $0 != pgid }
    }

    /// Everything readable now; nil when nothing (or EOF / an error) was read.
    private static func drain(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data.isEmpty ? nil : data
    }

    // MARK: Quitting

    private static func installQuitHooks() {
        let install = registryLock.withLock {
            defer { quitHooksInstalled = true }
            return !quitHooksInstalled
        }
        guard install else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            stopAllForQuit()
        }
        atexit { QuartoChild.killAll() }
        // A plain `kill <app>` (and `Scripts/run-isolated.sh --stop`) ends the app with neither of the above: stop the children,
        // then die of the SIGTERM as before.
        Darwin.signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler {
            stopAllForQuit(grace: 2)
            Darwin.signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }
        term.resume()
        registryLock.withLock { termSource = term }
    }

    nonisolated(unsafe) private static var termSource: DispatchSourceSignal?

    /// The app is quitting: SIGTERM to every group, up to `grace` for them to go, then SIGKILL. Blocks the calling (main) thread; the
    /// exits are handled on the children's own queues meanwhile.
    /// `only` narrows it to some process groups (tests run several children at once).
    static func stopAllForQuit(grace: TimeInterval = 3, only: ((pid_t) -> Bool)? = nil) {
        let children = registryLock.withLock { live.values.filter { only?($0.pid) ?? true } }
        guard !children.isEmpty else { return }
        children.forEach { $0.signal(SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while children.contains(where: { !$0.hasExited }), Date() < deadline { usleep(20_000) }
        children.forEach { $0.signal(SIGKILL) }
    }

    /// Last resort (`atexit`): SIGKILL to every group still known.
    static func killAll() {
        let children = registryLock.withLock { Array(live.values) }
        children.forEach { $0.signal(SIGKILL) }
    }
}

/// The `--log-format json-stream` log: one JSON object per line, `{"msg", "level", "levelName"}` (level 40 = ERROR, 50 = CRITICAL).
enum QuartoLog {
    static func errors(in file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return errors(inLog: data)
    }

    static func errors(inLog data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let level = (object["level"] as? NSNumber)?.intValue, level >= 40,
                  let message = object["msg"] as? String
            else { return nil }
            let text = QuartoConsole.clean(message).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
