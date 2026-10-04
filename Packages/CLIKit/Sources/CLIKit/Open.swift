import Foundation
import WorkspaceKit

/// `macdown2 [paths…]`: hand the files and folders to MacDown2.0 through `/usr/bin/open`.
///
/// Why `open` and not `NSWorkspace`: `NSWorkspace` is AppKit, which would load a GUI framework into a terminal tool and risks a
/// Dock tile; `open -a` is the same LaunchServices call, it names this very app bundle (so a dev build and an installed copy do
/// not get mixed up), and it reports failure through its exit status.
enum Open {
    static let stdinDirectoryVariable = "MACDOWN2_STDIN_DIR"
    /// Forwarded to a new instance so a Debug build launched through the CLI stays inside its isolation (Scripts/run-isolated.sh).
    static let isolationVariables = ["MACDOWN2_DEFAULTS_SUITE", "MACDOWN2_ALLOWED_ROOT"]

    static func run(_ args: OpenArgs, host: CLIHost) throws {
        var urls: [URL] = []
        if args.paths.isEmpty {
            // Piped text with no file named: open it. Nothing piped (a terminal, /dev/null, a launcher): just bring the app up.
            if !host.stdinIsTTY {
                let data = host.readStdin()
                if !data.isEmpty { urls.append(try spool(data, host: host)) }
            }
        }
        var spooled: URL?  // a second `-` means the same text, which is already read
        for path in args.paths {
            if path == "-" {
                if spooled == nil { spooled = try spool(host.readStdin(), host: host) }
                urls.append(spooled!)
            } else {
                urls.append(try CLI.resolve(path, host: host))
            }
        }
        let arguments = openArguments(urls: urls, host: host)
        if let layout = args.layout, urls.isEmpty {
            throw CLIError(ExitCode.usage, "\(layout.flag) needs a file or folder to apply to")
        }
        if args.dryRun {
            host.out((["open"] + arguments).map(shellQuoted).joined(separator: " ") + "\n")
            if let layout = args.layout { host.out("# layout: \(layout.rawValue), told to the app through \(hintDirectory(host: host).path)\n") }
            return
        }
        if let layout = args.layout { recordLayout(layout, for: urls, host: host) }
        let status = host.launch(arguments)
        guard status == 0 else { throw CLIError(ExitCode.unavailable, "could not open MacDown2.0 (open exited with status \(status))") }
    }

    /// The arguments for `/usr/bin/open`: this app bundle (or the bundle id when the CLI runs outside one), then the paths.
    /// Absolute paths always start with `/`, so none can be mistaken for an option.
    static func openArguments(urls: [URL], host: CLIHost) -> [String] {
        var arguments: [String] = []
        if host.environment[isolationVariables[0]]?.isEmpty == false {
            arguments += ["-n"]  // a second instance, or the files would land in the user's real MacDown2.0
            for name in isolationVariables { if let value = host.environment[name], !value.isEmpty { arguments += ["--env", "\(name)=\(value)"] } }
        }
        arguments += host.appBundle.map { ["-a", $0.path] } ?? ["-b", CLIHost.bundleIdentifier]
        return arguments + urls.map(\.path)
    }

    // MARK: layout flag

    static func hintDirectory(host: CLIHost) -> URL {
        LayoutHints.directory(home: host.home, suite: host.environment[isolationVariables[0]])
    }

    /// The app reads this hint when it is asked to open one of these paths (see `LayoutHints`). Written before `open` runs, so it is
    /// there however fast the app is. A failure is reported but does not stop the files from opening.
    static func recordLayout(_ layout: SplitMode, for urls: [URL], host: CLIHost) {
        do {
            try LayoutHints.write(layout, for: urls.map(\.fileKey), in: hintDirectory(host: host), now: host.now())
        } catch {
            host.err("macdown2: could not pass \(layout.flag) to the app (\(error.localizedDescription)); opening with its usual layout\n")
        }
    }

    // MARK: stdin

    /// `~/Library/Caches/io.github.xuanji86.MacDown2/stdin`, or `$MACDOWN2_STDIN_DIR`.
    static func stdinDirectory(host: CLIHost) -> URL {
        if let override = host.environment[stdinDirectoryVariable], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return host.home.appending(path: "Library/Caches/\(CLIHost.bundleIdentifier)/stdin", directoryHint: .isDirectory)
    }

    /// `yyyyMMdd-HHmmss-SSS.md` in local time: sorts by time, no characters that need quoting.
    static func stdinFileName(date: Date, timeZone: TimeZone, attempt: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date) + (attempt > 1 ? "-\(attempt)" : "") + ".md"
    }

    /// Saves piped text as a new file in the stdin folder. lazy: nothing prunes the folder (it is a cache); upgrade = delete files older than a month here.
    static func spool(_ data: Data, host: CLIHost) throws -> URL {
        let directory = stdinDirectory(host: host)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw CLIError(ExitCode.noInput, "cannot create \(directory.path): \(error.localizedDescription)")
        }
        let date = host.now()
        // Two pipes in the same millisecond get -2, -3…; `.withoutOverwriting` makes the existence check and the write one step.
        for attempt in 1...1000 {
            let file = directory.appending(path: stdinFileName(date: date, timeZone: host.timeZone, attempt: attempt))
            do {
                try data.write(to: file, options: .withoutOverwriting)
                return file
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw CLIError(ExitCode.noInput, "cannot write \(file.path): \(error.localizedDescription)")
            }
        }
        throw CLIError(ExitCode.noInput, "cannot find a free file name in \(directory.path)")
    }

    /// Fine in a terminal and in a copy-pasted command line; `'` is the only character that needs care inside single quotes.
    static func shellQuoted(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-=:+,@%".contains($0)) }
        return safe && !s.isEmpty ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
