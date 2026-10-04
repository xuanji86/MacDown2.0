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
    /// in its process group) and throw when the calling task is cancelled: callers use cancellation to enforce timeouts.
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
/// started, not just the shell), stdin and stderr on /dev/null, every other descriptor closed in the child.
public struct SystemProcessSpawner: ProcessSpawner {
    public init() {}

    public func run(executable: String, arguments: [String], directory: String) async throws -> ProcessOutput {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try child.runBlocking(executable: executable, arguments: arguments, directory: directory) })
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

        /// Kill the whole group. Safe at any time: before the spawn it only records the request; the pid stays a zombie
        /// (so it cannot be reused) until `runBlocking` reaps it under the same lock.
        func terminate() {
            lock.withLock {
                terminated = true
                if pid > 0 { kill(-pid, SIGKILL) }
            }
        }

        func runBlocking(executable: String, arguments: [String], directory: String) throws -> ProcessOutput {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw ProcessSpawnError.launchFailed(errno: errno) }
            let (readEnd, writeEnd) = (fds[0], fds[1])
            defer { close(readEnd) }

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
            var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
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

            var data = Data()
            var tooLarge = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readEnd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                if data.count + n > SystemProcessSpawner.outputLimit {
                    tooLarge = true
                    terminate()
                    break
                }
                data.append(buffer, count: n)
            }

            // Wait for the exit without reaping, then reap under the lock so `terminate` never signals a recycled pid.
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
            var status: Int32 = 0
            let wasTerminated: Bool = lock.withLock {
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
