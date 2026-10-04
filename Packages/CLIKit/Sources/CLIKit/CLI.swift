import Foundation

public enum CLI {
    /// Runs one invocation and returns the process exit status.
    public static func run(_ arguments: [String], host: CLIHost) async -> Int32 {
        do {
            switch try Arguments.parse(arguments) {
            case .help:
                host.out(Arguments.help + "\n")
            case .version:
                host.out("macdown2 \(host.version)\n")
            case .open(let args):
                try Open.run(args, host: host)
            case .render(let args):
                try await Render.run(args, host: host)
            }
            return ExitCode.ok
        } catch let error as CLIError {
            host.err("macdown2: \(error.message)\n")
            return error.code
        } catch {
            host.err("macdown2: \(error.localizedDescription)\n")
            return ExitCode.software
        }
    }

    /// `path` as typed → an absolute file URL, relative to the current directory. Symlinks are left alone (the app opens
    /// what the user named); a missing path is an error here rather than a silent no-op in `open`.
    static func resolve(_ path: String, host: CLIHost) throws -> URL {
        guard !path.isEmpty else { throw CLIError(ExitCode.noInput, "empty path") }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: host.currentDirectory)
        let absolute = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: absolute.path) else {
            throw CLIError(ExitCode.noInput, "no such file or directory: \(path)")
        }
        return absolute
    }
}
