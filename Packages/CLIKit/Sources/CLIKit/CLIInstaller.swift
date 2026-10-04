import Foundation

/// The app menu's "Install Command Line Tool…": a symlink to `Contents/Helpers/macdown2` in a folder the user can already write to.
/// No administrator rights, no `/usr/local/bin`. The app does the asking and showing (and the words, in the user's language);
/// the decisions live here so they are tested.
public enum CLIInstaller {
    /// What is at the tool's path when it is not our link.
    public enum Occupant: Equatable, Sendable {
        /// A symbolic link; `to` is its target as written.
        case link(to: String)
        /// A regular file or a folder.
        case file
    }

    public enum State: Equatable {
        case notInstalled
        case installed  // already points at this app's tool
        /// A link into another (or a deleted) MacDown2 bundle: ours to replace, after asking.
        case elsewhere(Occupant)
        /// Anything that is not a MacDown2 link: a regular file or folder, or a link to some other program. Never replaced.
        case foreign(Occupant)
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
            let written = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent())
            if written.resolvingSymlinksInPath().path == helper.resolvingSymlinksInPath().path { return .installed }
            // Judged on the path as written, not resolved: the other copy may be gone (a dangling link is still ours to replace).
            return pointsIntoMacDown2Bundle(written) ? .elsewhere(.link(to: target)) : .foreign(.link(to: target))
        }
        // `fileExists` follows links and would call a dangling one absent, but a dangling link is handled above.
        return fm.fileExists(atPath: link.path) ? .foreign(.file) : .notInstalled
    }

    /// `…/MacDown2*.app/Contents/Helpers/macdown2`: where this installer's links point, in whichever copy of the app.
    static func pointsIntoMacDown2Bundle(_ target: URL) -> Bool {
        let parts = target.standardizedFileURL.pathComponents
        guard parts.count >= 4, Array(parts.suffix(3)) == ["Contents", "Helpers", toolName] else { return false }
        let app = parts[parts.count - 4]
        return app.hasPrefix("MacDown2") && app.hasSuffix(".app")
    }

    public enum InstallError: Error, Equatable {
        /// The app bundle has no tool to link to.
        case helperMissing(URL)
        /// The tool's name is taken by something that is not ours; it was left alone.
        case foreign(link: URL, Occupant)
    }

    /// Creates `<directory>/macdown2`. With `replace` an existing link into a MacDown2 bundle is removed first; anything else
    /// (a regular file, a folder, a link to another program) is never touched and throws.
    @discardableResult
    public static func install(helper: URL, into directory: URL, replace: Bool) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helper.path) else { throw InstallError.helperMissing(helper) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appending(path: toolName)
        if replace {
            // Decided here, not by the caller's earlier look: what is at `link` right now is what counts.
            if case .foreign(let occupant) = state(link: link, helper: helper) { throw InstallError.foreign(link: link, occupant) }
            try? fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        return link
    }

    /// Whether `directory` is on the PATH of a normal Homebrew setup, so no hint is needed. A GUI app cannot see the shell's PATH;
    /// for any other folder the app can only tell the user to check, not check for them.
    public static func isOnHomebrewPath(_ directory: URL) -> Bool { directory.path == "/opt/homebrew/bin" }
}
