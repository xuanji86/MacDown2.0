import AppKit
import CLIKit
import SwiftUI

/// App menu > Install Command Line Tool…: links `macdown2` (inside this app) into `/opt/homebrew/bin` or `~/.local/bin`.
/// No administrator rights are ever requested; the rules are in `CLIInstaller` (tested), the words are here.
struct CommandLineToolCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Install Command Line Tool…") { CommandLineToolInstaller.run() }
        }
    }
}

@MainActor
enum CommandLineToolInstaller {
    static func run() {
        let helper = CLIInstaller.helper(in: Bundle.main.bundleURL)
        let directory = CLIInstaller.directory(home: FileManager.default.homeDirectoryForCurrentUser)
        let link = directory.appending(path: CLIInstaller.toolName)
        var replace = false
        switch CLIInstaller.state(link: link, helper: helper) {
        case .installed:
            show(
                String(localized: "Command Line Tool Installed"),
                String(localized: "\(link.path) already points to this MacDown2.0.\n\nRun macdown2 --help in Terminal to see how to use it.")
            )
            return
        case .elsewhere(let occupant):
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace the existing macdown2?")
            alert.informativeText = String(localized: "\(link.path) is currently \(describe(occupant)). Replacing it points it to this MacDown2.0.")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            replace = true
        case .foreign(let occupant):
            // Not ours (a regular file, a folder, a link to another program): never offered for replacement.
            show(String(localized: "Could Not Install the Command Line Tool"), foreignMessage(link: link, occupant), style: .warning)
            return
        case .notInstalled:
            break
        }
        do {
            try CLIInstaller.install(helper: helper, into: directory, replace: replace)
            show(String(localized: "Command Line Tool Installed"), "\(link.path) → \(helper.path)\n\n\(pathHint(directory: directory))")
        } catch let error as CLIInstaller.InstallError {
            switch error {
            case .helperMissing(let helper):
                show(String(localized: "Could Not Install the Command Line Tool"), String(localized: "\(helper.path) is missing; this build has no command line tool."), style: .warning)
            case .foreign(let link, let occupant):
                show(String(localized: "Could Not Install the Command Line Tool"), foreignMessage(link: link, occupant), style: .warning)
            }
        } catch {
            show(String(localized: "Could Not Install the Command Line Tool"), error.localizedDescription, style: .warning)
        }
    }

    private static func describe(_ occupant: CLIInstaller.Occupant) -> String {
        switch occupant {
        case .link(let target): String(localized: "a link to \(target)")
        case .file: String(localized: "an existing file")
        }
    }

    private static func foreignMessage(link: URL, _ occupant: CLIInstaller.Occupant) -> String {
        String(localized: "\(link.path) is \(describe(occupant)), not a MacDown2.0 link, so it was left alone. Move or remove it yourself and install again.")
    }

    /// What to tell the user about PATH. A GUI app cannot see the shell's PATH, so this is a hint, not a check.
    private static func pathHint(directory: URL) -> String {
        if CLIInstaller.isOnHomebrewPath(directory) { return String(localized: "/opt/homebrew/bin is on the PATH of a normal Homebrew setup.") }
        return String(localized: "Make sure \(directory.path) is on your PATH. If `macdown2` is not found in a new terminal, add this to ~/.zshrc:\nexport PATH=\"$HOME/.local/bin:$PATH\"")
    }

    private static func show(_ title: String, _ detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
