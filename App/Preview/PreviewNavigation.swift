import AppKit
import MarkdownCore
import OSLog
import WebKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "preview")

/// The preview page never navigates anywhere: every navigation is either the page's own load / an in-page anchor, or it is
/// cancelled and (for a link the user clicked) handled here. The rules live in `MarkdownCore.LinkPolicy` (pure, tested);
/// this performs the answer.
///
///   in-page `#anchor`                  allowed, WebKit scrolls to the `id` / `<a name>` (the page also scrolls by itself)
///   `.md` / `.qmd` in the workspace    opened in the app, through the same route as File > Open
///   any other `file://`                asks, then the system opens it; apps, scripts and other executables are refused
///   `http(s)`, `mailto`                the system
///   everything else                    cancelled; the rendered page is untouched
struct PreviewNavigationDecider: WebPage.NavigationDeciding {
    let root: DocumentRoot
    /// File > Open's route (tabs in the front window); replaceable in tests.
    var openDocument: @MainActor (URL) -> Void = { WorkspaceRegistry.shared.open([$0]) }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, !action.shouldPerformDownload else { return .cancel }
        let roots = [root.url].compactMap { $0 } + root.workspaceRoots
        let decision = LinkPolicy(pageURL: PreviewAssetHandler.previewURL, roots: roots)
            .decide(url, isLinkActivation: action.navigationType == .linkActivated)
        if decision == .allow { return .allow }
        perform(decision, for: url)
        return .cancel
    }

    @MainActor private func perform(_ decision: LinkPolicy.Decision, for url: URL) {
        switch decision {
        case .allow:
            break
        case .openInApp(let file):
            openDocument(file)
        case .openExternally(let target):
            NSWorkspace.shared.open(target)
        case .confirmOpenWithSystem(let file):
            Self.confirmOpen(file)
        case .refuse(let reason):
            log.notice("preview navigation refused (\(String(describing: reason), privacy: .public)): \(url.absoluteString.prefix(200), privacy: .private)")
            switch reason {
            case .executable: Self.alert(String(localized: "Blocked a link to a program"), String(localized: "MacDown2 does not open applications, scripts or installers from a document link."))
            case .missing: NSSound.beep()
            default: break
            }
        }
    }

    @MainActor private static func confirmOpen(_ file: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open “\(file.lastPathComponent)” with its default app?")
        alert.informativeText = file.path
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open"))
        present(alert) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(file) }
        }
    }

    @MainActor private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        present(alert) { _ in }
    }

    @MainActor private static func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
}
