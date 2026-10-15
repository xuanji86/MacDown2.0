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
///   missing `.md` / `.qmd` in the      asks, then creates it empty and opens it in a new tab (`LinkPolicy.offerToCreate`)
///   document's folder
///   any other `file://`                asks, then the system opens it; apps, scripts and other executables are refused
///   `http(s)`, `mailto`                the system
///   everything else                    cancelled; the rendered page is untouched
struct PreviewNavigationDecider: WebPage.NavigationDeciding {
    let root: DocumentRoot
    /// File > Open's route (tabs in the front window); replaceable in tests.
    var openDocument: @MainActor (URL) -> Void = { WorkspaceRegistry.shared.open([$0]) }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, !action.shouldPerformDownload else { return .cancel }
        let decision = policy.decide(url, isLinkActivation: action.navigationType == .linkActivated)
        if decision == .allow { return .allow }
        perform(decision, for: url)
        return .cancel
    }

    /// `createIn` is the document's own folder (nil while it is unsaved: a link to a missing note then does nothing).
    private var policy: LinkPolicy {
        LinkPolicy(pageURL: PreviewAssetHandler.previewURL, roots: [root.url].compactMap { $0 } + root.workspaceRoots, createIn: root.url)
    }

    @MainActor private func perform(_ decision: LinkPolicy.Decision, for url: URL) {
        switch decision {
        case .allow:
            break
        case .openInApp(let file):
            openDocument(file)
        case .offerToCreate(let file):
            confirmCreate(file, for: url)
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

    /// A sheet, not a modal loop: the editor stays alive underneath (the original MacDown froze on this link). The policy is asked again
    /// at the click, so a folder swapped for a symlink while the sheet was up is not written through.
    @MainActor private func confirmCreate(_ file: URL, for link: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(file.lastPathComponent)” doesn’t exist. Create it?")
        alert.informativeText = file.deletingLastPathComponent().path
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Create"))
        Self.present(alert) { response in
            guard response == .alertSecondButtonReturn else { return }
            guard AppDefaults.permitsOpening(file), policy.decide(link, isLinkActivation: true) == .offerToCreate(file) else { return NSSound.beep() }
            if let failure = Self.createEmptyFile(at: file) {
                Self.alert(String(localized: "Could not create “\(file.lastPathComponent)”"), failure)
            } else {
                openDocument(file)
            }
        }
    }

    /// An empty file that did not exist (`O_EXCL`), not through a symlink (`O_NOFOLLOW`). Nil on success, else the reason.
    private static func createEmptyFile(at file: URL) -> String? {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { return NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription }
        close(descriptor)
        return nil
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
