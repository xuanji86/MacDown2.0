import AppKit
import CLIKit
import SwiftUI

/// App menu > Install Command Line Tool…: links `macdown2` (inside this app) into `/opt/homebrew/bin` or `~/.local/bin`.
/// No administrator rights are ever requested; the rules are in `CLIInstaller` (tested).
struct CommandLineToolCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("安装命令行工具…") { CommandLineToolInstaller.run() }
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
            show("命令行工具已安装", "\(link.path) 已指向这个 MacDown2.0。\n\n在终端里运行 macdown2 --help 查看用法。")
            return
        case .elsewhere(let what):
            let alert = NSAlert()
            alert.messageText = "要覆盖现有的 macdown2 吗？"
            alert.informativeText = "\(link.path) 现在是\(what)。覆盖后它会指向这个 MacDown2.0。"
            alert.addButton(withTitle: "覆盖")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            replace = true
        case .foreign(let what):
            // Not ours (a regular file, a folder, a link to another program): never offered for replacement.
            show("无法安装命令行工具", CLIInstaller.foreignMessage(link: link, what: what), style: .warning)
            return
        case .notInstalled:
            break
        }
        do {
            try CLIInstaller.install(helper: helper, into: directory, replace: replace)
            show("命令行工具已安装", "\(link.path) → \(helper.path)\n\n\(CLIInstaller.pathHint(directory: directory))")
        } catch {
            show("无法安装命令行工具", error.localizedDescription, style: .warning)
        }
    }

    private static func show(_ title: String, _ detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
