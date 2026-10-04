import Foundation

/// Everything the command reads from or does to the outside world, so tests can run it without a terminal, a clock or an app.
public struct CLIHost: Sendable {
    public var currentDirectory: URL
    public var environment: [String: String]
    public var home: URL
    /// The real (symlinks resolved) path of the running `macdown2`; where the enclosing MacDown2.app and the version come from.
    public var executable: URL?
    public var stdinIsTTY: Bool
    public var readStdin: @Sendable () -> Data
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var now: @Sendable () -> Date
    public var timeZone: TimeZone
    /// MacDown2.0's own preferences (render switches, preview style, extension switches); nil = defaults.
    public var appDefaults: @Sendable () -> UserDefaults?
    /// Runs `/usr/bin/open` with these arguments and returns its exit status.
    public var launch: @Sendable ([String]) -> Int32

    public static let bundleIdentifier = "io.github.xuanji86.MacDown2"

    public static func live() -> CLIHost {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        return CLIHost(
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser,
            executable: executable,
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) },
            now: { Date() },
            timeZone: .current,
            appDefaults: { UserDefaults(suiteName: bundleIdentifier) },
            launch: { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = arguments
                do { try process.run() } catch { return -1 }
                process.waitUntilExit()
                return process.terminationStatus
            }
        )
    }

    /// The `MacDown2.app` this binary lives in (`…/MacDown2.app/Contents/Helpers/macdown2`), nil when run from a build folder.
    var appBundle: URL? {
        var dir = executable?.deletingLastPathComponent()
        while let current = dir, current.path != "/" {
            if current.pathExtension == "app" { return current }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Same number as the app: its Info.plist.
    var version: String {
        let plist = appBundle?.appending(path: "Contents/Info.plist")
        let info = plist.flatMap { NSDictionary(contentsOf: $0) }
        return info?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
