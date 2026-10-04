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
    /// A task-list checkbox was clicked (`Web/src/preview/tasks.ts`): the page's per-load token, the 0-based source line of
    /// its item, the state the user asked for, and the render version the page shows.
    case toggleTask(token: String, line: Int, checked: Bool, version: Int)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "scroll":
            guard let line = (dict["line"] as? NSNumber)?.doubleValue else { return nil }
            self = .scroll(line: line)
        case "error":
            self = .error(stage: dict["stage"] as? String ?? "?", message: dict["message"] as? String ?? "")
        case "toggleTask":
            guard let token = dict["token"] as? String,
                  let line = (dict["line"] as? NSNumber)?.intValue, line >= 0,
                  let checked = (dict["checked"] as? NSNumber)?.boolValue,
                  let version = (dict["version"] as? NSNumber)?.intValue
            else { return nil }
            self = .toggleTask(token: token, line: line, checked: checked, version: version)
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
    /// The task-list checkboxes of the text the page shows (`TaskToggle` edits from these).
    var tasks: [TaskItem]
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
    /// The user clicked a task checkbox on the page and the page's token and render version check out: edit the source
    /// (`task` as the renderer saw it in `text`, the Markdown the page shows; `checked` the wanted state). Returns the document's new text
    /// when it made the edit, nil when it refused; the page is then told to take the checkbox back.
    var onToggleTask: ((_ task: TaskItem, _ checked: Bool, _ text: String) -> String?)?

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

    /// Folders of the open workspace; a relative link to a `.md`/`.qmd` anywhere under them (or under the document's folder)
    /// opens in the app instead of asking the system.
    var workspaceRoots: [URL] {
        get { documentRoot.workspaceRoots }
        set { documentRoot.workspaceRoots = newValue }
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
    /// Secret of the current page load, given to the page once it has loaded; a message that does not carry it is dropped.
    /// Not persisted anywhere: a new load (or a new launch) has a new one.
    private var bridgeToken: String?
    /// The text the page shows, and the version it was given (every render gets the next one; the page reports the one it
    /// shows with each checkbox click), and the checkboxes the renderer found in it (nil until that render has answered: a
    /// click in that instant is refused). Set before the render is sent and put back if it fails. nil until the first render.
    private var shown: (version: Int, text: String, tasks: [TaskItem]?)?
    private var renderCount = 0
    // Same latest-wins collapsing for scroll requests.
    private var pendingScrollLine: Double?
    private var lastLine = 0.0  // top source line the preview was last scrolled to, by the user or by `scroll(toLine:)`
    private var scrolling = false
    // Preview style as last chosen; (re)applied once the page has loaded and on every change.
    private var style: (light: String, dark: String?) = PreviewStyles.resolve(id: PreviewStyles.defaultID, followSystem: false)
    private var pageLoaded = false
    /// The Block remote images setting the current page was loaded with (it is part of the page's CSP); nil before the first load.
    private var loadedBlockingImages: Bool?
    /// Bumped by `clear()`: a render that started before it must not publish its metadata.
    private var clearEpoch = 0

    init(options: RenderOptions = RenderSettings.current) {
        self.options = options
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[URLScheme(PreviewAssetHandler.scheme)!] = PreviewAssetHandler(documentRoot: documentRoot)
        configuration.userContentController.add(messages, name: "macdown2")
        page = WebPage(configuration: configuration, navigationDecider: PreviewNavigationDecider(root: documentRoot))
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
        let resolved = options.rendering(as: flavor, markdown: markdown, readFile: QuartoIncludes.fileReader(directory: documentDirectory))
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
        lastLine = line
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

    /// Something in the document's folder changed on disk: when an image the page loaded from there is different now (or
    /// gone), load the page afresh and render again at the same line. Why not just re-render: inside one page load WebKit
    /// hands an `<img>` with a URL it already loaded the old picture, whatever the response headers say (checked: the
    /// handler's `no-store` does not help), and the only other cure is rewriting URLs inside the page's own code.
    /// Cheap when nothing it showed changed; one flash when something did.
    func refreshChangedResources() {
        let changed = documentRoot.changedServedFiles()
        guard !changed.isEmpty, lastMarkdown != nil else { return }
        log.info("preview: \(changed.count) image(s) changed on disk, reloading the page")
        documentRoot.forgetServedFiles()
        Task { await reloadPage() }
    }

    /// A setting that lives in the page's own CSP changed (Block remote images): the page is read again with the new policy.
    /// Compared with the policy the page was loaded with, so it also catches a change made while no preview pane was around
    /// (the window showed no document) and does nothing when the page already has the current one.
    func reloadForPolicyChange() {
        guard let loaded = loadedBlockingImages, loaded != RemoteContent.blocksImages(in: AppDefaults.store) else { return }
        Task { await reloadPage() }
    }

    /// The window shows no document any more: what the page last reported (the sidebar's outline, the counts) goes, and nothing
    /// still on its way (a debounced or running render) brings it back. The page keeps its old content out of sight until the
    /// next document's text replaces it.
    func clear() {
        clearEpoch += 1
        debounce?.cancel()
        pending = nil
        lastMarkdown = nil
        shown = nil
        metadata = nil
    }

    private func reloadPage() async {
        let line = lastLine
        pageLoaded = false
        loading = nil
        needsRebuild = true
        guard await ensureLoaded(), let markdown = lastMarkdown else { return }  // the text as it is after the load, not before
        await push(markdown)
        scroll(toLine: line)
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
            lastLine = line
            onVisibleLineChange?(line)
        case .error(let stage, let text):
            log.error("preview \(stage, privacy: .public) error: \(text, privacy: .public)")
            onRenderError?(text)
        case .toggleTask(let token, let line, let checked, let version):
            toggleTask(token: token, line: line, checked: checked, version: version)
        }
    }

    /// Anything but a click on the page we last loaded, showing the text we last rendered, is ignored: a stale click can only
    /// mean the text moved on (typing, another tab) and the next render is on its way. The editor then re-checks the line
    /// against the text it holds now (`TaskToggle`) and makes the change as one undo step.
    private func toggleTask(token: String, line: Int, checked: Bool, version: Int) {
        guard token == bridgeToken else {
            log.error("preview task toggle dropped: wrong token")
            return
        }
        if let shown, shown.version == version, let task = shown.tasks?.first(where: { $0.line == line }),
           let new = onToggleTask?(task, checked, shown.text) {
            // Render the new text now instead of after the typing debounce: a second click inside that window would be stale.
            lastMarkdown = new
            Task { [weak self] in await self?.push(new) }
        } else {
            log.info("preview task toggle refused (line \(line), version \(version))")
            Task { [page] in _ = try? await page.callJavaScript("MacDown2Preview.resyncTasks()") }
        }
    }

    private func ensureLoaded() async -> Bool {
        if let loading { return await loading.value }
        loadedBlockingImages = RemoteContent.blocksImages(in: AppDefaults.store)
        let task = Task { [page] () -> Bool in
            do {
                for try await event in page.load(PreviewAssetHandler.previewURL) where event == .finished {
                    await self.styleAfterLoad()
                    await self.giveToken()
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

    /// A fresh token per load; the page keeps task checkboxes disabled until it has one.
    private func giveToken() async {
        let token = UUID().uuidString
        bridgeToken = token
        shown = nil
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setTaskToken(token)", arguments: ["token": token])
        } catch {
            log.error("preview token failed: \(String(describing: error), privacy: .public)")
        }
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
            // Relative links resolve against the document's folder (as a file URL, trailing slash); see Web/src/preview/links.ts.
            let base = documentDirectory.map { URL(filePath: $0.path, directoryHint: .isDirectory).absoluteString }
            renderCount += 1
            let version = renderCount
            let before = shown
            let epoch = clearEpoch
            shown = (version, next, nil)
            do {
                // A chunk that fails to load is reported by `update` itself (the flavor is then unknown).
                let result = try await page.callJavaScript(
                    "await MacDown2Preview.useFlavor(flavor).catch(() => {}); MacDown2Preview.setBase(base); if (rebuild) MacDown2Preview.invalidate(); return MacDown2Preview.update(md, options, version)",
                    arguments: ["md": next, "options": optionsJSON, "rebuild": rebuild, "flavor": flavorFiles, "base": base.map { $0 as Any } ?? NSNull(), "version": version]
                )
                let elapsed = ContinuousClock.now - started
                // Render failures are reported over the bridge (`handle`); success carries blocks/outline/stats/perf.
                let meta = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                if meta?["error"] != nil { shown = before }  // the old content stays on the page
                if meta?["error"] == nil {
                    if epoch == clearEpoch, let decoded = try? JSONDecoder().decode(PreviewMetadata.self, from: Data((result as? String ?? "").utf8)) {
                        if decoded != metadata { metadata = decoded }
                        if shown?.version == version { shown?.tasks = decoded.tasks }
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
                shown = before
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
    @AppStorage(RemoteContent.blockImagesKey) private var blockRemoteImages = false
    private let renderSettings = RenderSettings.shared

    var body: some View {
        WebView(model.page)
            .webViewContentBackground(.hidden)
            .overlay(alignment: .top) { PreviewNotices(badge: flavor?.badge, hint: AppExtensions.disabledHint(for: documentURL)) }
            // `initial`: the pane is gone while the window shows no document, and settings changed meanwhile must still arrive.
            .onChange(of: renderSettings.options, initial: true) { _, options in model.setOptions(options) }
            .onChange(of: "\(style)|\(followsSystem)", initial: true) { model.setStyle(id: style, followSystem: followsSystem) }
            .onChange(of: flavor?.id, initial: true) { model.setFlavor(flavor) }
            .onChange(of: blockRemoteImages, initial: true) { model.reloadForPolicyChange() }
            // Restarts with the document: the page stays, the text it renders is the active tab's.
            .task(id: ObjectIdentifier(document)) {
                for await text in document.$text.values { model.schedule(text) }
            }
            // Only the document shown here is followed; the monitor of a document in a background tab does not reach a preview.
            .task(id: ObjectIdentifier(document)) {
                for await _ in NotificationCenter.default.notifications(named: .markdownDocumentFolderChanged, object: document).map({ _ in () }) {
                    model.refreshChangedResources()
                }
            }
            .onChange(of: documentURL, initial: true) { _, url in model.documentDirectory = url?.deletingLastPathComponent() }
    }
}
