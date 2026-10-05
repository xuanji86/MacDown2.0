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
    /// The page's selection as a source range of the text of render `version`, nil when there is none (`Web/src/preview/peer.ts`).
    case selection(token: String, version: Int, range: NSRange?)
    /// A text edit made in the preview (`Web/src/preview/editing.ts`).
    case edit(token: String, edit: PreviewEdit)
    /// The page held a render back while an edit or an input method was in flight and wants the current text again.
    case resync(token: String)

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
        case "selection":
            guard let token = dict["token"] as? String,
                  let version = (dict["version"] as? NSNumber)?.intValue,
                  let from = (dict["from"] as? NSNumber)?.intValue, let to = (dict["to"] as? NSNumber)?.intValue
            else { return nil }
            self = .selection(token: token, version: version, range: from >= 0 && to > from ? NSRange(location: from, length: to - from) : nil)
        case "previewEdit":
            guard let token = dict["token"] as? String,
                  let base = (dict["base"] as? NSNumber)?.intValue, let seq = (dict["seq"] as? NSNumber)?.intValue, seq >= 1,
                  let from = (dict["from"] as? NSNumber)?.intValue, let to = (dict["to"] as? NSNumber)?.intValue, from >= 0, to >= from,
                  let text = dict["text"] as? String
            else { return nil }
            self = .edit(token: token, edit: PreviewEdit(base: base, seq: seq, range: NSRange(location: from, length: to - from), replacement: text))
        case "resync":
            guard let token = dict["token"] as? String else { return nil }
            self = .resync(token: token)
        default:
            return nil
        }
    }
}

/// Settings ▸ Rendering ▸ "Edit in preview" (default on): text-level editing inside the preview.
enum PreviewEditingKey {
    static let enabled = "previewEditing"
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
    /// A text edit made in the preview that fits the burst it belongs to (`PreviewEditChain`): apply it to the editor, which must
    /// hold exactly `expectedText`. Returns the document's new text, or nil when it refused (the page then shows the app's text).
    var onPreviewEdit: ((_ edit: PreviewEdit, _ expectedText: String) -> String?)?
    /// The page's selection as a range of `text` (the Markdown the page shows), nil when it has none: the editor shows it.
    var onPreviewSelection: ((_ range: NSRange?, _ text: String) -> Void)?

    /// Directory that relative image paths resolve against; nil for a document that was never saved.
    var documentDirectory: URL? {
        didSet {
            guard documentDirectory != oldValue else { return }
            documentRoot.url = documentDirectory
            includes = IncludeFileCache(directory: documentDirectory)
            // Images already rendered point at macdown2-res://doc/... and failed or showed another file: rebuild once.
            needsRebuild = true
            if let lastMarkdown { schedule(lastMarkdown) }
        }
    }

    /// The pane now shows `document` (called first in its per-document task, before any of its text arrives). A different document
    /// drops the previous one's text everywhere (`lastMarkdown`, `pending`, `displayed`, a waiting render; `clearEpoch` keeps one
    /// in flight from publishing), so the one-frame delay can never render the old text with the new base or flavor: the new
    /// document's first text renders instead. The same document with another folder or flavor still re-renders (the setters,
    /// which `PreviewPane`'s onChange handlers also reach, before or after this: whichever comes second is a no-op).
    func show(document: ObjectIdentifier, directory: URL?, flavor: (any DocumentFlavor)?) {
        if document != currentDocument {
            currentDocument = document
            dropText()
            needsRebuild = true
        }
        documentDirectory = directory
        setFlavor(flavor)
    }

    /// Forgets the text of the document that was shown; nothing still on its way (a waiting or running render) publishes or comes back.
    private func dropText() {
        clearEpoch += 1
        debounce?.cancel()
        pending = nil
        lastMarkdown = nil
        displayed = nil
        editChain.reset()
        editorSelection = nil
    }

    /// Folders of the open workspace; a relative link to a `.md`/`.qmd` anywhere under them (or under the document's folder)
    /// opens in the app instead of asking the system.
    var workspaceRoots: [URL] {
        get { documentRoot.workspaceRoots }
        set { documentRoot.workspaceRoots = newValue }
    }

    private let documentRoot = DocumentRoot()
    /// The Quarto include files the renders read, so a render re-reads only what changed and a folder event can tell an include moved on.
    private var includes = IncludeFileCache(directory: nil)
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
    /// The render the page displays: its version (every render gets the next one; the page reports the one it shows with each
    /// checkbox click), the text, and the checkboxes the renderer found in it. Set when a render LANDS (not when it starts), so a
    /// click on what the page still shows is matched while a newer render is in flight; a click that arrives before the
    /// landing carries a newer version than this and is refused. A failed render leaves it (and the page) as it was.
    /// nil until the first render, and after `clear()`, a document switch or a page load.
    private var displayed: (version: Int, text: String, tasks: [TaskItem])?
    /// The document `lastMarkdown` belongs to (`show`).
    private var currentDocument: ObjectIdentifier?
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
    /// The preview edits applied so far in the page's current burst (`PreviewEditChain`), and whether editing is on at all.
    private var editChain = PreviewEditChain()
    private var editingEnabled = true
    /// The editor's selection to show on the page, with the text it is a range of; shown only while that is the text the page shows.
    private var editorSelection: (range: NSRange, text: String)?

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
        let resolved = options.rendering(as: flavor, markdown: markdown, readFile: includes.read)
        includes.endRender()
        return (resolved.json, ["chunks": resolved.renderChunks, "stylesheets": flavor?.previewStylesheets ?? []])
    }

    /// The document's text as the editor has it now. Text the page already shows or is about to (a task checkbox click renders its
    /// own result at once, and the edit then reaches here too) is not rendered a second time; `schedule` always renders.
    func textChanged(_ markdown: String) {
        if markdown != lastMarkdown { schedule(markdown) }
    }

    /// Renders on the next display frame: changes within one frame (a paste, key repeat) collapse into one render, which is cheap
    /// (incremental, a few ms even on large files). The latest call wins; `push` keeps one render in flight.
    func schedule(_ markdown: String) {
        lastMarkdown = markdown
        debounce?.cancel()
        let frame = Self.frameInterval
        debounce = Task { [weak self] in
            try? await Task.sleep(for: frame)
            guard !Task.isCancelled else { return }
            await self?.push(markdown)
        }
    }

    /// One refresh interval of the main screen (8 ms at 120 Hz); ~16 ms when it is unknown.
    private static var frameInterval: Duration {
        let seconds = NSScreen.main?.minimumRefreshInterval ?? 0
        return .seconds(seconds > 0 ? seconds : 1.0 / 60)
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
    /// Cheap when nothing it showed changed; one flash when something did. A Quarto include file that changed needs no reload,
    /// only a render (its text is part of the options the page is given).
    func refreshChangedResources() {
        guard let lastMarkdown else { return }
        let changed = documentRoot.changedServedFiles()
        if !changed.isEmpty {
            log.info("preview: \(changed.count) image(s) changed on disk, reloading the page")
            documentRoot.forgetServedFiles()
            Task { await reloadPage() }
        } else if includes.changed() {
            log.info("preview: an include file changed on disk, rendering again")
            schedule(lastMarkdown)
        }
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
        dropText()
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
        case .selection(let token, let version, let range):
            guard token == bridgeToken else { return }
            if let range, let displayed, displayed.version == version {
                onPreviewSelection?(range, displayed.text)
            } else if range == nil {
                onPreviewSelection?(nil, displayed?.text ?? "")
            }
        case .edit(let token, let edit):
            previewEdit(token: token, edit: edit)
        case .resync(let token):
            guard token == bridgeToken, let lastMarkdown else { return }
            debounce?.cancel()
            Task { [weak self] in await self?.push(lastMarkdown) }
        }
    }

    /// An edit made in the preview: applied only on exactly the text it was made on (the burst's chain, then the editor's own check),
    /// rendered at once (the page holds back renders that do not contain all its edits yet). Anything else is refused: the page is
    /// told and shown the app's text.
    private func previewEdit(token: String, edit: PreviewEdit) {
        guard token == bridgeToken else {
            log.error("preview edit dropped: wrong token")
            return
        }
        if editingEnabled, let expected = editChain.expectedText(for: edit, displayed: displayed.map { ($0.version, $0.text) }),
           PreviewEditChain.isApplicable(edit, to: expected), let new = onPreviewEdit?(edit, expected) {
            editChain.accept(edit, result: new)
            lastMarkdown = new
            debounce?.cancel()  // a render of older text still waiting would otherwise land after this one
            Task { [weak self] in await self?.push(new) }
        } else {
            log.info("preview edit refused (burst \(edit.base), edit \(edit.seq))")
            editChain.reset()
            Task { [page] in _ = try? await page.callJavaScript("MacDown2Preview.editRefused('stale')") }
            if let text = lastMarkdown ?? displayed?.text { Task { [weak self] in await self?.push(text) } }
        }
    }

    /// Settings ▸ Rendering ▸ Edit in preview. The page gets it with every load too (`giveToken`).
    func setEditing(enabled: Bool) {
        guard enabled != editingEnabled else { return }
        editingEnabled = enabled
        if pageLoaded { Task { await applyEditing() } }
    }

    private func applyEditing() async {
        let hints: [String: String] = [
            "newline": String(localized: "Line breaks and new paragraphs are made in the editor."),
            "paste": String(localized: "Formatted text can only be pasted in the editor."),
            "formatting": String(localized: "This edit crosses formatting: make it in the editor."),
            "unmapped": String(localized: "This text cannot be edited in the preview: edit it in the editor."),
            "structure": String(localized: "That change belongs in the editor."),
            "stale": String(localized: "The text changed meanwhile: the preview shows it again."),
        ]
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setEditing({ enabled, hints })", arguments: ["enabled": editingEnabled, "hints": hints])
        } catch {
            log.error("preview editing setup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The editor's selection (nil or empty: none), as a range of `text`, the document's text now. Shown on the page as a highlight
    /// while the page shows that same text; kept, and shown again after each render.
    func showEditorSelection(_ range: NSRange?, in text: String) {
        if let range, range.length > 0 {
            editorSelection = (range, text)
        } else {
            editorSelection = nil
        }
        Task { await applyEditorSelection() }
    }

    private func applyEditorSelection() async {
        guard pageLoaded, let displayed else { return }
        var arguments: [String: Any] = ["from": -1, "to": -1, "version": displayed.version]
        if let selection = editorSelection, selection.text == displayed.text {
            arguments["from"] = selection.range.location
            arguments["to"] = NSMaxRange(selection.range)
        }
        _ = try? await page.callJavaScript("MacDown2Preview.highlightSource(from, to, version)", arguments: arguments)
    }

    /// Anything but a click on the page we last loaded, showing the text we last rendered, is ignored: a stale click can only
    /// mean the text moved on (typing, another tab) and the next render is on its way. The editor then re-checks the line
    /// against the text it holds now (`TaskToggle`) and makes the change as one undo step.
    private func toggleTask(token: String, line: Int, checked: Bool, version: Int) {
        guard token == bridgeToken else {
            log.error("preview task toggle dropped: wrong token")
            return
        }
        // Matched against the render that landed (`displayed`), not the newest one started; `onToggleTask` still refuses unless the
        // editor holds exactly that text, so a click on a page that is out of date by an edit changes nothing.
        if let displayed, displayed.version == version, let task = displayed.tasks.first(where: { $0.line == line }),
           let new = onToggleTask?(task, checked, displayed.text) {
            // Render the new text now instead of after the next frame: a second click inside that window would be stale.
            lastMarkdown = new
            debounce?.cancel()  // a render of older text still waiting would otherwise land after this one
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
        let loaded = await task.value
        if !loaded, loading == task { loading = nil }  // a failed load is tried again by the next push or scroll, not remembered
        return loaded
    }

    /// Before the first render, so a non-default style never shows a white frame first.
    private func styleAfterLoad() async {
        pageLoaded = true
        await applyStyle()
    }

    /// A fresh token per load; the page keeps task checkboxes disabled (and editing off) until it has one.
    private func giveToken() async {
        let token = UUID().uuidString
        bridgeToken = token
        displayed = nil
        editChain.reset()
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setTaskToken(token)", arguments: ["token": token])
        } catch {
            log.error("preview token failed: \(String(describing: error), privacy: .public)")
        }
        await applyEditing()
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
            let epoch = clearEpoch
            // The page's preview edits this text contains (the page holds back a render that does not contain all of them yet).
            let mark: Any = editChain.mark(for: next).map { ["base": $0.base, "seq": $0.seq] as [String: Int] } ?? NSNull()
            do {
                // A chunk that fails to load is reported by `update` itself (the flavor is then unknown).
                let result = try await page.callJavaScript(
                    "await MacDown2Preview.useFlavor(flavor).catch(() => {}); MacDown2Preview.setBase(base); if (rebuild) MacDown2Preview.invalidate(); return MacDown2Preview.update(md, options, version, edit)",
                    arguments: ["md": next, "options": optionsJSON, "rebuild": rebuild, "flavor": flavorFiles, "base": base.map { $0 as Any } ?? NSNull(), "version": version, "edit": mark]
                )
                let elapsed = ContinuousClock.now - started
                // Render failures are reported over the bridge (`handle`); success carries blocks/outline/stats/perf.
                let meta = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                if meta?["deferred"] as? Bool == true {
                    // Held back by the page: it still shows the previous render (and more); `displayed` stays as it is.
                    if rebuild { needsRebuild = true }
                    log.info("preview update held back by the page (edit in flight)")
                } else if meta?["error"] == nil {
                    // A render that started before `clear()` / a document switch must not publish: its text is not the pane's any more.
                    if epoch == clearEpoch, let decoded = try? JSONDecoder().decode(PreviewMetadata.self, from: Data((result as? String ?? "").utf8)) {
                        if decoded != metadata { metadata = decoded }
                        displayed = (version, next, decoded.tasks)
                        if editorSelection != nil { await applyEditorSelection() }  // the render dropped the page's highlight
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
    @AppStorage(RemoteContent.blockImagesKey) private var blockRemoteImages = false
    @AppStorage(PreviewEditingKey.enabled) private var previewEditing = true
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
            .onChange(of: previewEditing, initial: true) { _, on in model.setEditing(enabled: on) }
            // Restarts with the document: the page stays, the text it renders is the active tab's.
            .task(id: ObjectIdentifier(document)) {
                model.show(document: ObjectIdentifier(document), directory: documentURL?.deletingLastPathComponent(), flavor: flavor)
                for await text in document.$text.values { model.textChanged(text) }
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
