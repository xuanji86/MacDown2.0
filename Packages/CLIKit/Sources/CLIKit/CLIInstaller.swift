import Foundation

/// The app menu's "Install Command Line Tool…": a symlink to `Contents/Helpers/macdown2` in a folder the user can already write to.
/// No administrator rights, no `/usr/local/bin`. The app does the asking and showing; the decisions live here so they are tested.
public enum CLIInstaller {
    public enum State: Equatable {
        case notInstalled
        case installed  // already points at this app's tool
        case elsewhere(String)  // something else is there; the text says what, for the "replace it?" question
    }

    public static let toolName = "macdown2"

    public static func helper(in app: URL) -> URL { app.appending(path: "Contents/Helpers/\(toolName)") }

    /// `/opt/homebrew/bin` when it exists and is writable (the usual Homebrew setup), else `~/.local/bin` (made if missing).
    public static func directory(home: URL, homebrew: URL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: homebrew.path, isDirectory: &isDirectory), isDirectory.boolValue,
           FileManager.default.isWritableFile(atPath: homebrew.path) { return homebrew }
        return home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    public static func state(link: URL, helper: URL) -> State {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).resolvingSymlinksInPath().path
            return resolved == helper.resolvingSymlinksInPath().path ? .installed : .elsewhere("a link to \(target)")
        }
        // `fileExists` follows links and would call a dangling one absent, but a dangling link is handled above.
        return fm.fileExists(atPath: link.path) ? .elsewhere("an existing file") : .notInstalled
    }

    public struct InstallError: Error, LocalizedError {
        public let errorDescription: String?
    }

    /// Creates `<directory>/macdown2`. With `replace` an existing link or file is removed first; a folder is never touched.
    @discardableResult
    public static func install(helper: URL, into directory: URL, replace: Bool) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helper.path) else { throw InstallError(errorDescription: "\(helper.path) is missing; this build has no command line tool.") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appending(path: toolName)
        if replace {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: link.path, isDirectory: &isDirectory), isDirectory.boolValue, (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
                throw InstallError(errorDescription: "\(link.path) is a folder; not replacing it.")
            }
            try? fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        return link
    }

    /// What to tell the user about PATH. A GUI app cannot see the shell's PATH, so this is a hint, not a check.
    public static func pathHint(directory: URL) -> String {
        if directory.path == "/opt/homebrew/bin" { return "/opt/homebrew/bin is on the PATH of a normal Homebrew setup." }
        return "Make sure \(directory.path) is on your PATH. If `macdown2` is not found in a new terminal, add this to ~/.zshrc:\nexport PATH=\"$HOME/.local/bin:$PATH\""
    }
}
