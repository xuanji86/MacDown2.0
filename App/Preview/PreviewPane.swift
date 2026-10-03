import AppKit
import MarkdownCore
import OSLog
import SwiftUI
import WebKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "preview")

/// Owns the `WebPage` that shows `preview.html` and pushes Markdown into it.
@MainActor
final class PreviewModel {
    let page: WebPage
    private let optionsJSON: String
    private var loading: Task<Bool, Never>?
    private var debounce: Task<Void, Never>?
    // Updates arriving while a JS call is in flight collapse into `pending`; the latest text always wins, in order.
    private var pending: String?
    private var pushing = false

    init() {
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[URLScheme(PreviewAssetHandler.scheme)!] = PreviewAssetHandler()
        page = WebPage(configuration: configuration, navigationDecider: ExternalLinkDecider())
        #if DEBUG
        page.isInspectable = true
        #endif
        optionsJSON = (try? String(data: JSONEncoder().encode(RenderOptions()), encoding: .utf8)) ?? "{}"
    }

    /// Debounced (~150 ms) so typing bursts render once.
    func schedule(_ markdown: String) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.push(markdown)
        }
    }

    private func ensureLoaded() async -> Bool {
        if let loading { return await loading.value }
        let task = Task { [page] () -> Bool in
            do {
                for try await event in page.load(PreviewAssetHandler.previewURL) where event == .finished { return true }
                return false
            } catch {
                log.error("preview load failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        loading = task
        return await task.value
    }

    private func push(_ markdown: String) async {
        pending = markdown
        guard !pushing else { return }
        pushing = true
        defer { pushing = false }
        guard await ensureLoaded() else { return }
        while let next = pending {
            pending = nil
            do {
                let result = try await page.callJavaScript(
                    "return MacDown2Preview.update(md, options)",
                    arguments: ["md": next, "options": optionsJSON]
                )
                // The page reports render errors as `{"error": ...}` instead of throwing; success carries blocks/outline/stats.
                let meta = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                if let message = meta?["error"] {
                    log.error("preview render error: \(String(describing: message), privacy: .public)")
                } else {
                    log.info("preview updated: blocks=\((meta?["blocks"] as? [Any])?.count ?? -1) bytes=\(next.utf8.count)")
                }
            } catch {
                log.error("preview update failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

struct PreviewPane: View {
    @ObservedObject var document: MarkdownDocument
    @State private var model = PreviewModel()

    var body: some View {
        WebView(model.page)
            .webViewContentBackground(.hidden)
            .onReceive(document.$text) { model.schedule($0) }
    }
}

/// Keeps the preview page in place: only our own scheme loads in the view; web links open in the browser.
struct ExternalLinkDecider: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.scheme != PreviewAssetHandler.scheme, url.scheme != "about" else { return .allow }
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        return .cancel
    }
}
