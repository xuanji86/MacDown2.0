import AppKit
import MarkdownCore
import OSLog
import SwiftUI
import WebKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "preview")

/// What the page sends over `window.webkit.messageHandlers.macdown2` (see `Web/src/preview/bridge.ts`).
enum PreviewMessage: Equatable {
    case scroll(line: Double)  // 0-based, fractional source line at the top of the viewport
    case error(stage: String, message: String)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "scroll":
            guard let line = (dict["line"] as? NSNumber)?.doubleValue else { return nil }
            self = .scroll(line: line)
        case "error":
            self = .error(stage: dict["stage"] as? String ?? "?", message: dict["message"] as? String ?? "")
        default:
            return nil
        }
    }
}

/// `userContentController.add` retains its handler, so this object only holds a closure that points back weakly.
@MainActor
private final class PreviewMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((PreviewMessage) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let parsed = PreviewMessage(body: message.body) else { return }
        onMessage?(parsed)
    }
}

/// Owns the `WebPage` that shows `preview.html` and pushes Markdown into it.
@MainActor
final class PreviewModel {
    let page: WebPage

    /// Top visible source line after the user scrolled the preview (0-based, fractional). Throttled to one per frame
    /// inside the page. Not called for scrolls caused by `scroll(toLine:)`.
    var onVisibleLineChange: ((Double) -> Void)?
    /// A render or script error inside the page (the old content stays on screen).
    var onRenderError: ((String) -> Void)?

    /// Directory that relative image paths resolve against; nil for a document that was never saved.
    var documentDirectory: URL? {
        didSet {
            guard documentDirectory != oldValue else { return }
            documentRoot.url = documentDirectory
            // Images already rendered point at macdown2-res://doc/... and failed or showed another file: rebuild once.
            needsRebuild = true
            if let lastMarkdown { schedule(lastMarkdown) }
        }
    }

    private let documentRoot = DocumentRoot()
    private let messages = PreviewMessageHandler()
    private let optionsJSON: String
    private var loading: Task<Bool, Never>?
    private var debounce: Task<Void, Never>?
    // Updates arriving while a JS call is in flight collapse into `pending`; the latest text always wins, in order.
    private var pending: String?
    private var pushing = false
    private var lastMarkdown: String?
    private var needsRebuild = false
    // Same latest-wins collapsing for scroll requests.
    private var pendingScrollLine: Double?
    private var scrolling = false

    init() {
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[URLScheme(PreviewAssetHandler.scheme)!] = PreviewAssetHandler(documentRoot: documentRoot)
        configuration.userContentController.add(messages, name: "macdown2")
        page = WebPage(configuration: configuration, navigationDecider: ExternalLinkDecider())
        #if DEBUG
        page.isInspectable = true
        #endif
        optionsJSON = (try? String(data: JSONEncoder().encode(RenderOptions()), encoding: .utf8)) ?? "{}"
        messages.onMessage = { [weak self] message in self?.handle(message) }
    }

    /// Debounced (~150 ms) so typing bursts render once.
    func schedule(_ markdown: String) {
        lastMarkdown = markdown
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.push(markdown)
        }
    }

    /// Scrolls the preview so `line` (0-based, fractional ok) is at the top. Instant; the page does not echo it back
    /// through `onVisibleLineChange`. Latest call wins if several arrive while one is running.
    func scroll(toLine line: Double) {
        pendingScrollLine = line
        guard !scrolling else { return }
        scrolling = true
        Task {
            defer { scrolling = false }
            guard await ensureLoaded() else { return }
            while let next = pendingScrollLine {
                pendingScrollLine = nil
                do {
                    _ = try await page.callJavaScript("MacDown2Preview.scrollToLine(line)", arguments: ["line": next])
                } catch {
                    log.error("preview scroll failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func handle(_ message: PreviewMessage) {
        switch message {
        case .scroll(let line):
            onVisibleLineChange?(line)
        case .error(let stage, let text):
            log.error("preview \(stage, privacy: .public) error: \(text, privacy: .public)")
            onRenderError?(text)
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
            let rebuild = needsRebuild
            needsRebuild = false
            let started = ContinuousClock.now
            do {
                let result = try await page.callJavaScript(
                    "if (rebuild) MacDown2Preview.invalidate(); return MacDown2Preview.update(md, options)",
                    arguments: ["md": next, "options": optionsJSON, "rebuild": rebuild]
                )
                let elapsed = ContinuousClock.now - started
                // Render failures are reported over the bridge (`handle`); success carries blocks/outline/stats/perf.
                let meta = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                if meta?["error"] == nil {
                    let perf = meta?["perf"] as? [String: Any]
                    let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
                    let mode = perf?["mode"] as? String ?? "?"
                    let jsRender = perf?["render"] as? Double ?? -1
                    let jsPatch = perf?["patch"] as? Double ?? -1
                    let jsSplit = perf?["split"] as? Double ?? -1
                    let jsApply = perf?["apply"] as? Double ?? -1
                    let blocks = (meta?["blocks"] as? [Any])?.count ?? -1
                    log.info("preview updated: mode=\(mode, privacy: .public) swift_to_done_ms=\(ms, format: .fixed(precision: 1)) js_render_ms=\(jsRender, format: .fixed(precision: 1)) js_patch_ms=\(jsPatch, format: .fixed(precision: 1)) (split \(jsSplit, format: .fixed(precision: 1)) apply \(jsApply, format: .fixed(precision: 1))) blocks=\(blocks) bytes=\(next.utf8.count)")
                }
            } catch {
                log.error("preview update failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

struct PreviewPane: View {
    @ObservedObject var document: MarkdownDocument
    /// File URL of the document (nil while unsaved); relative images resolve against its folder.
    var documentURL: URL?
    @State private var model = PreviewModel()

    var body: some View {
        WebView(model.page)
            .webViewContentBackground(.hidden)
            .onReceive(document.$text) { model.schedule($0) }
            .onChange(of: documentURL, initial: true) { _, url in model.documentDirectory = url?.deletingLastPathComponent() }
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
