import Darwin
import Foundation

/// What a finished child process left behind.
public struct ProcessOutput: Sendable, Equatable {
    public var stdout: Data
    /// Exit status; 128 + signal number when it was killed by a signal.
    public var status: Int32

    public init(stdout: Data, status: Int32) {
        self.stdout = stdout
        self.status = status
    }
}

/// Starts external processes. Injected so tests never touch the user's real shell (and can count spawns).
public protocol ProcessSpawner: Sendable {
    /// Runs `executable` in `directory` with stdin closed and returns its stdout. Must stop the process (and everything
    /// in its process group) and throw promptly when the calling task is cancelled: callers use cancellation to enforce
    /// timeouts.
    func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput
}

public enum ProcessSpawnError: Error, LocalizedError, Equatable {
    case launchFailed(errno: Int32)
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let code): "could not launch (\(String(cString: strerror(code))))"
        case .outputTooLarge: "output too large"
        }
    }
}

/// The real thing: `posix_spawn` into a new process group (so a timeout can kill the shell and whatever its rc files
/// started in the group), stdin and stderr on /dev/null, every other descriptor closed in the child.
///
/// stdout is read with `poll`, together with a wake-up pipe, so neither a cancel nor the shell's exit waits for the pipe
/// to reach EOF: a descendant that called `setsid()` and kept stdout open cannot hold the call up.
public struct SystemProcessSpawner: ProcessSpawner {
    /// The child's environment; nil = this process's own.
    private let environment: [String: String]?

    public init(environment: [String: String]? = nil) { self.environment = environment }

    public func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        let child = Child()
        let environment = environment ?? ProcessInfo.processInfo.environment
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try child.runBlocking(executable: executable, arguments: arguments, directory: directory, environment: environment) })
                }
            }
        } onCancel: {
            child.terminate()
        }
    }

    // lazy: 4 MB of stdout is the cap (an environment is a few KB); no streaming
    private static let outputLimit = 4 << 20

    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var terminated = false
        private var wakeWriter: Int32 = -1

        /// Kill the whole group and wake the reader. Safe at any time: before the spawn it only records the request; the
        /// pid stays a zombie (so it cannot be reused) until `runBlocking` reaps it under the same lock.
        func terminate() {
            lock.withLock {
                terminated = true
                if pid > 0 { kill(-pid, SIGKILL) }
                wake()
            }
        }

        private func wake() {  // caller holds the lock; the writer is only closed under it
            if wakeWriter >= 0 { var byte: UInt8 = 1; _ = write(wakeWriter, &byte, 1) }
        }

        func runBlocking(executable: String, arguments: [String], directory: String, environment: [String: String]) throws -> ProcessOutput {
            var out: [Int32] = [0, 0], wake: [Int32] = [0, 0]
            guard pipe(&out) == 0 else { throw ProcessSpawnError.launchFailed(errno: errno) }
            guard pipe(&wake) == 0 else {
                close(out[0]); close(out[1])
                throw ProcessSpawnError.launchFailed(errno: errno)
            }
            let (readEnd, writeEnd, wakeReader) = (out[0], out[1], wake[0])
            for fd in [readEnd, wakeReader, wake[1]] {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
            _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
            let cancelledEarly: Bool = lock.withLock {
                wakeWriter = wake[1]
                return terminated
            }
            defer {
                lock.withLock { wakeWriter = -1 }
                close(readEnd); close(wakeReader); close(wake[1])
            }
            if cancelledEarly {
                close(writeEnd)
                throw CancellationError()
            }

            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addchdir(&actions, directory)
            var defaultSignals = sigset_t(), noSignals = sigset_t()
            sigfillset(&defaultSignals)
            sigemptyset(&noSignals)
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

            var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }

            var child: pid_t = 0
            let rc = posix_spawn(&child, executable, &actions, &attributes, &argv, &envp)
            close(writeEnd)
            guard rc == 0 else { throw ProcessSpawnError.launchFailed(errno: rc) }
            lock.withLock {
                pid = child
                if terminated { kill(-child, SIGKILL) }
            }

            // The shell's exit also wakes the reader, so a descendant that kept stdout open cannot hold us up.
            // `WNOWAIT`: the zombie stays until we reap it below, so `terminate` never signals a recycled pid.
            let exited = DispatchSemaphore(value: 0)
            let reaped = child
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                while waitid(P_PID, id_t(reaped), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
                self.lock.withLock { self.wake() }
                exited.signal()
            }

            var data = Data()
            var tooLarge = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            /// Reads what is there; false at EOF.
            func drain() -> Bool {
                while true {
                    let n = read(readEnd, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 { return true }  // EAGAIN: nothing more for now
                    if n == 0 { return false }
                    if data.count + n > SystemProcessSpawner.outputLimit {
                        tooLarge = true
                        return false
                    }
                    data.append(buffer, count: n)
                }
            }
            var fds = [pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0)]
            polling: while true {
                if poll(&fds, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    terminate()  // cannot wait any more: stop the child rather than leave it
                    break
                }
                if fds[0].revents != 0, !drain() {
                    if tooLarge { terminate(); break }
                    fds[0].fd = -1  // EOF: keep waiting for the exit (or a cancel)
                }
                if fds[1].revents != 0 {
                    _ = drain()  // what the shell wrote before exiting is already in the pipe
                    break polling
                }
            }
            exited.wait()  // the shell exited (or was killed by `terminate`), so this returns

            var status: Int32 = 0
            let wasTerminated = lock.withLock {
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                pid = 0
                return terminated
            }
            if tooLarge { throw ProcessSpawnError.outputTooLarge }
            if wasTerminated { throw CancellationError() }
            let signal = status & 0x7f
            return ProcessOutput(stdout: data, status: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        }
    }
}
