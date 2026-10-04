import AppKit
import ExtensionAPI
import MarkdownCore
import Observation
import OSLog
import SwiftUI
import WebAssets
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

/// What the page reports after each render (`MacDown2Preview.update`) that the rest of the window shows: the outline
/// (with `line`s, 0-based) and the whole-document counts.
struct PreviewMetadata: Decodable, Equatable {
    var outline: [OutlineItem]
    var stats: TextStats
}

/// Owns the `WebPage` that shows `preview.html` and pushes Markdown into it.
@MainActor @Observable
final class PreviewModel {
    let page: WebPage

    /// Metadata of the last successful render; nil until the first one finishes.
    private(set) var metadata: PreviewMetadata?

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
    /// The Markdown / Rendering settings; the document's flavor is added per render (`resolvedOptions`).
    private var options: RenderOptions
    private var flavor: (any DocumentFlavor)?
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
    // Preview style as last chosen; (re)applied once the page has loaded and on every change.
    private var style: (light: String, dark: String?) = PreviewStyles.resolve(id: PreviewStyles.defaultID, followSystem: false)
    private var pageLoaded = false

    init(options: RenderOptions = RenderSettings.current) {
        self.options = options
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[URLScheme(PreviewAssetHandler.scheme)!] = PreviewAssetHandler(documentRoot: documentRoot)
        configuration.userContentController.add(messages, name: "macdown2")
        page = WebPage(configuration: configuration, navigationDecider: ExternalLinkDecider())
        #if DEBUG
        page.isInspectable = true
        #endif
        messages.onMessage = { [weak self] message in self?.handle(message) }
    }

    private static func json(_ options: RenderOptions) -> String {
        (try? String(data: JSONEncoder().encode(options), encoding: .utf8)) ?? "{}"
    }

    /// New render settings. The page rebuilds the whole document when it sees a different options string, so this only
    /// has to push the current text again.
    func setOptions(_ new: RenderOptions) {
        guard new != options else { return }
        options = new
        if let lastMarkdown { schedule(lastMarkdown) }
    }

    /// The flavor an enabled extension gives this document (nil = plain Markdown), e.g. Quarto for a .qmd. Changing it
    /// re-renders; the options string then differs (flavor id), so the page rebuilds, and the flavor's chunk and
    /// stylesheets are loaded (or its stylesheets dropped) before the render.
    func setFlavor(_ new: (any DocumentFlavor)?) {
        guard new?.id != flavor?.id else { return }
        flavor = new
        if let lastMarkdown { schedule(lastMarkdown) }
    }

    /// Options for rendering `markdown` now (settings + flavor + the files the flavor reads), as the page's JSON, and
    /// the chunks and stylesheets to have loaded first.
    private func resolvedOptions(for markdown: String) -> (json: String, flavor: [String: [String]]) {
        let resolved = options.rendering(as: flavor, markdown: markdown, readFile: AppExtensions.fileReader(directory: documentDirectory))
        return (Self.json(resolved), ["chunks": resolved.renderChunks, "stylesheets": flavor?.previewStylesheets ?? []])
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

    /// Switches the preview style (and its highlight.js theme) in place; the page is not reloaded. With `followSystem` the
    /// page itself switches between the style and its light/dark partner via `prefers-color-scheme`.
    func setStyle(id: String, followSystem: Bool) {
        style = PreviewStyles.resolve(id: id, followSystem: followSystem)
        if pageLoaded { Task { await applyStyle() } }
    }

    // Always sends the latest choice, so overlapping calls end on the last one (WebKit runs them in the order sent).
    private func applyStyle() async {
        let (light, dark) = style
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setStyle(light, dark)", arguments: ["light": light, "dark": dark.map { $0 as Any } ?? NSNull()])
        } catch {
            log.error("preview style failed: \(String(describing: error), privacy: .public)")
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
                for try await event in page.load(PreviewAssetHandler.previewURL) where event == .finished {
                    await self.styleAfterLoad()
                    return true
                }
                return false
            } catch {
                log.error("preview load failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        loading = task
        return await task.value
    }

    /// Before the first render, so a non-default style never shows a white frame first.
    private func styleAfterLoad() async {
        pageLoaded = true
        await applyStyle()
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
            let (optionsJSON, flavorFiles) = resolvedOptions(for: next)
            do {
                // A chunk that fails to load is reported by `update` itself (the flavor is then unknown).
                let result = try await page.callJavaScript(
                    "await MacDown2Preview.useFlavor(flavor).catch(() => {}); if (rebuild) MacDown2Preview.invalidate(); return MacDown2Preview.update(md, options)",
                    arguments: ["md": next, "options": optionsJSON, "rebuild": rebuild, "flavor": flavorFiles]
                )
                let elapsed = ContinuousClock.now - started
                // Render failures are reported over the bridge (`handle`); success carries blocks/outline/stats/perf.
                let meta = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                if meta?["error"] == nil {
                    if let decoded = try? JSONDecoder().decode(PreviewMetadata.self, from: Data((result as? String ?? "").utf8)), decoded != metadata {
                        metadata = decoded
                    }
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
    let document: MarkdownDocument
    /// File URL of the document (nil while unsaved); relative images resolve against its folder.
    var documentURL: URL?
    /// Owned by `DocumentView` so scroll sync can drive it.
    let model: PreviewModel
    /// What an enabled extension makes of this document (Quarto for a .qmd); nil = plain Markdown.
    var flavor: (any DocumentFlavor)?
    @AppStorage(AppearanceKey.previewStyle) private var style = AppearanceDefault.previewStyle
    @AppStorage(AppearanceKey.previewStyleFollowsSystem) private var followsSystem = false
    private let renderSettings = RenderSettings.shared

    var body: some View {
        WebView(model.page)
            .webViewContentBackground(.hidden)
            .overlay(alignment: .top) { PreviewNotices(badge: flavor?.badge, hint: AppExtensions.disabledHint(for: documentURL)) }
            .onChange(of: renderSettings.options) { _, options in model.setOptions(options) }
            .onChange(of: "\(style)|\(followsSystem)", initial: true) { model.setStyle(id: style, followSystem: followsSystem) }
            .onChange(of: flavor?.id, initial: true) { model.setFlavor(flavor) }
            // Restarts with the document: the page stays, the text it renders is the active tab's.
            .task(id: ObjectIdentifier(document)) {
                for await text in document.$text.values { model.schedule(text) }
            }
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
