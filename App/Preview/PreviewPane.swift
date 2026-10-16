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
    /// A task-list checkbox was clicked (`Web/src/preview/tasks.ts`): the page's per-load token, the checkbox as the render found it
    /// (its item's 0-based source line, the line and column of its `[ ]` mark), the state the user asked for, and the render version
    /// the page shows.
    case toggleTask(token: String, task: TaskItem, checked: Bool, version: Int)
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
                  let mark = (dict["mark"] as? NSNumber)?.intValue, let column = (dict["column"] as? NSNumber)?.intValue,
                  let checked = (dict["checked"] as? NSNumber)?.boolValue,
                  let version = (dict["version"] as? NSNumber)?.intValue
            else { return nil }
            self = .toggleTask(token: token, task: TaskItem(line: line, mark: mark, column: column), checked: checked, version: version)
        case "selection":
            guard let token = dict["token"] as? String,
                  let version = (dict["version"] as? NSNumber)?.intValue,
                  let from = (dict["from"] as? NSNumber)?.intValue, let to = (dict["to"] as? NSNumber)?.intValue
            else { return nil }
            self = .selection(token: token, version: version, range: from >= 0 && to > from ? NSRange(location: from, length: to - from) : nil)
        case "previewEdit":
            guard let token = dict["token"] as? String, let burst = (dict["burst"] as? NSNumber)?.intValue,
                  let base = (dict["base"] as? NSNumber)?.intValue, let seq = (dict["seq"] as? NSNumber)?.intValue, seq >= 1,
                  let from = (dict["from"] as? NSNumber)?.intValue, let to = (dict["to"] as? NSNumber)?.intValue, from >= 0, to >= from,
                  let text = dict["text"] as? String, let removed = dict["removed"] as? String,
                  let before = dict["before"] as? String, let after = dict["after"] as? String
            else { return nil }
            self = .edit(token: token, edit: PreviewEdit(
                burst: burst, base: base, seq: seq, range: NSRange(location: from, length: to - from), replacement: text,
                removed: removed, before: before, after: after, startsStep: (dict["step"] as? NSNumber)?.boolValue ?? true))
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

/// Settings ▸ Rendering ▸ "Update preview automatically" (default on). Off: only View ▸ Render Preview (⌘R) re-renders after an edit.
enum PreviewRenderKey {
    static let auto = "previewAutoRender"
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

/// What `MacDown2Preview.update` returns (`Web/src/preview/main.ts`): either `deferred`, an `error`, or the render's metadata and timings.
private struct UpdateReport: Decodable {
    var deferred: Bool?
    var error: String?
    var outline: [OutlineItem]?
    var stats: TextStats?
    var blockCount: Int?
    var perf: Perf?

    struct Perf: Decodable {
        var mode: String?
        var render: Double?
        var patch: Double?
        var split: Double?
        var apply: Double?
    }
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
    /// drops the previous one's text everywhere (`lastMarkdown`, `pending`, the renders sent, a waiting render; `clearEpoch` keeps one
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
        statsTask?.cancel()
        pending = nil
        lastMarkdown = nil
        editChain.reset()
        editorSelection = nil
        highlighted = nil
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
    private var zoomPercent = ViewZoom.actualSize
    private var autoRender = true
    /// The counts while the preview is paused (`scheduleStats`), and the renderer that makes them (created on first use).
    private var statsTask: Task<Void, Never>?
    private var statsRenderer: JSCRenderer?
    /// The Block remote images setting the current page was loaded with (it is part of the page's CSP); nil before the first load.
    private var loadedBlockingImages: Bool?
    /// Bumped by `clear()`: a render that started before it must not publish its metadata.
    private var clearEpoch = 0
    /// The preview edits applied so far in the page's current burst (`PreviewEditChain`), and whether editing is on at all.
    private var editChain = PreviewEditChain()
    private var editingEnabled = true
    /// The editor's selection to show on the page, with the text it is a range of; shown only while that is the text the page shows.
    private var editorSelection: (range: NSRange, text: String)?
    /// The latest editor selection not looked at yet (latest wins, one per frame while the user drags) and how to read the editor's text.
    private var pendingSelection: (() -> (NSRange, String)?)?
    private var selectionTask: Task<Void, Never>?
    /// What the page was last asked to highlight (version, from, to): asking again for the same is skipped.
    private var highlighted: (version: Int, from: Int, to: Int)?
    /// Quarto real render (PLAN 4.6.2): the page is a local server's instead of `preview.html`. While on, nothing is rendered, scrolled or
    /// taken from the page here (the status bar's counts still follow the text); `externalURL` is the page once there is one.
    private var externalActive = false
    private var externalURL: URL?
    /// The editor's top visible line (0-based): where the app's own page scrolls to when the real render is switched off.
    var editorLine: (() -> Double?)?

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

    #if DEBUG
    isolated deinit { debugLifetime.info("PreviewModel freed") }
    #endif

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
        if externalActive {
            lastMarkdown = markdown  // rendered when the app's page comes back
            scheduleStats(markdown)
            return
        }
        // With "Update preview automatically" off only a document's first text gets here (`renderNow` does the rest); `lastMarkdown` is then
        // the text the page shows, so every re-render for another reason (a setting, the style, the folder) keeps showing that text.
        guard PreviewRefresh.rendersOnEdit(autoRender: autoRender, hasRendered: lastMarkdown != nil) else {
            scheduleStats(markdown)  // the status bar's counts are the document's, not the page's
            return
        }
        // UTF-16 identity, not Swift's canonical `==`: a change from "é" to "e\u{301}" must reach the page, whose offsets are units.
        if !(lastMarkdown.map { markdown.isIdentical(to: $0) } ?? false) { schedule(markdown) }
    }

    /// With "Update preview automatically" off the page keeps its render, but the word and character counts in the status bar must follow
    /// the text. They come from a render of it in a private JavaScriptCore context (`JSCRenderer`, the same renderer and options, so the
    /// numbers are what the page would report), off the main thread, once the typing pauses; a newer text, a render or a document switch
    /// drops the one in flight.
    // lazy: a whole-document render per typing pause while paused; `TextStats(counting:)` is cheaper but counts the Markdown source, not the rendered text
    private func scheduleStats(_ markdown: String) {
        statsTask?.cancel()
        let epoch = clearEpoch
        statsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let resolved = options.rendering(as: flavor, markdown: markdown, readFile: QuartoIncludes.fileReader(directory: documentDirectory))
            do {
                let renderer: JSCRenderer
                if let statsRenderer { renderer = statsRenderer } else { renderer = try await .makeOffMain() }
                statsRenderer = renderer
                let stats = try await renderer.render(markdown, options: resolved).stats
                guard !Task.isCancelled, epoch == clearEpoch, metadata != nil, metadata?.stats != stats else { return }
                metadata?.stats = stats
            } catch {
                log.error("preview stats failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Settings ▸ Rendering ▸ Update preview automatically. Turning it on catches up with the edits made while it was off.
    func setAutoRender(_ on: Bool, text: String) {
        guard on != autoRender else { return }
        autoRender = on
        if on { textChanged(text) }
    }

    /// View ▸ Render Preview (⌘R), in either mode: renders `markdown` now (no frame of delay) and nothing else; no cache is cleared. An image
    /// of the document's folder that changed on disk is picked up the way a folder event picks it up (the page loads afresh, then renders).
    func renderNow(_ markdown: String) {
        lastMarkdown = markdown
        debounce?.cancel()
        statsTask?.cancel()
        if !documentRoot.changedServedFiles().isEmpty {
            refreshChangedResources()
        } else {
            Task { [weak self] in await self?.push(markdown) }
        }
    }

    /// Renders on the next display frame: changes within one frame (a paste, key repeat) collapse into one render, which is cheap
    /// (incremental, a few ms even on large files). The latest call wins; `push` keeps one render in flight.
    func schedule(_ markdown: String) {
        lastMarkdown = markdown
        debounce?.cancel()
        statsTask?.cancel()  // this render brings its own counts
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
        guard !externalActive else { return }  // no scroll sync with Quarto's page: it has no source lines
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

    private func reloadPage(line: Double? = nil) async {
        guard !externalActive else { return }
        let line = line ?? lastLine
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

    /// View ▸ Zoom: the page is scaled in place (no render, no reload; the page keeps the line at its top). Applied again after every load.
    func setZoom(percent: Int) {
        let clamped = ViewZoom.clamped(percent)
        guard clamped != zoomPercent else { return }
        zoomPercent = clamped
        if pageLoaded { Task { await applyZoom() } }
    }

    private func applyZoom() async {
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setZoom(factor)", arguments: ["factor": ViewZoom.factor(zoomPercent)])
        } catch {
            log.error("preview zoom failed: \(String(describing: error), privacy: .public)")
        }
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
        guard !externalActive else { return }  // Quarto's page is not ours: nothing it sends is taken
        switch message {
        case .scroll(let line):
            lastLine = line
            onVisibleLineChange?(line)
        case .error(let stage, let text):
            log.error("preview \(stage, privacy: .public) error: \(text, privacy: .public)")
        case .toggleTask(let token, let task, let checked, let version):
            toggleTask(token: token, task: task, checked: checked, version: version)
        case .selection(let token, let version, let range):
            guard token == bridgeToken else { return }
            // The render the page names may be one whose call has not returned yet: its text is known from when it was sent. A range
            // of a render no longer known (or none) clears the editor's highlight: it would be of another text.
            if let range, let text = editChain.text(ofRender: version) {
                onPreviewSelection?(range, text)
            } else {
                onPreviewSelection?(nil, "")
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
    /// told which edit and why, and (if it is still its burst) asks for the app's text with a resync; nothing else is sent.
    private func previewEdit(token: String, edit: PreviewEdit) {
        guard token == bridgeToken else {
            log.error("preview edit dropped: wrong token")
            return
        }
        let expected = editingEnabled ? editChain.expectedText(for: edit) : .failure(.stale)
        if case .success(let text) = expected, let new = onPreviewEdit?(edit, text) {
            editChain.accept(edit, result: new)
            lastMarkdown = new
            debounce?.cancel()  // a render of older text still waiting would otherwise land after this one
            Task { [weak self] in await self?.push(new) }
            return
        }
        let reason: PreviewEditRefusal = if case .failure(let why) = expected { why } else { .stale }
        log.info("preview edit refused (burst \(edit.burst) on render \(edit.base), edit \(edit.seq)): \(reason.rawValue, privacy: .public)")
        editChain.refused(edit)
        Task { [page] in
            _ = try? await page.callJavaScript("MacDown2Preview.editRefused(kind, burst, seq)", arguments: ["kind": reason.rawValue, "burst": edit.burst, "seq": edit.seq])
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

    /// The editor's selection changed; `read` gives its range and its text, read together. Looked at once per frame, the latest
    /// state (a drag selects many times), and shown on the page as a highlight while the page shows that same text; kept, and shown
    /// again after each render. An empty selection clears it.
    func showEditorSelection(read: @escaping () -> (NSRange, String)?) {
        pendingSelection = read
        guard selectionTask == nil else { return }
        let frame = Self.frameInterval
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: frame)
            guard let self else { return }
            selectionTask = nil
            guard let read = pendingSelection else { return }
            pendingSelection = nil
            if let (range, text) = read(), range.length > 0 {
                editorSelection = (range, text)
            } else {
                editorSelection = nil
            }
            await applyEditorSelection()
        }
    }

    private func applyEditorSelection() async {
        guard pageLoaded, let displayed = editChain.displayed else { return }
        var request = (version: displayed.version, from: -1, to: -1)
        if let selection = editorSelection, selection.text.isIdentical(to: displayed.text) {
            request.from = selection.range.location
            request.to = NSMaxRange(selection.range)
        }
        // Nothing new (still none, the same range on the same render): no call.
        if let last = highlighted, last.version == request.version, last.from == request.from, last.to == request.to { return }
        if request.from < 0, highlighted.map({ $0.from < 0 }) ?? true { highlighted = request; return }
        highlighted = request
        _ = try? await page.callJavaScript("MacDown2Preview.highlightSource(from, to, version)", arguments: ["from": request.from, "to": request.to, "version": request.version])
    }

    /// Only a click on the page we last loaded, on a render we sent and still know (`PreviewEditChain`, the same record edits and
    /// selections are matched against: a render whose call has not returned yet counts), is taken. The editor then checks that it
    /// holds exactly that render's text and that the task's mark is a `[ ]` / `[x]` there (`TaskToggle`), and makes the change as one
    /// undo step; a click on a page that is out of date by an edit changes nothing.
    private func toggleTask(token: String, task: TaskItem, checked: Bool, version: Int) {
        guard token == bridgeToken else {
            log.error("preview task toggle dropped: wrong token")
            return
        }
        if let text = editChain.text(ofRender: version), let new = onToggleTask?(task, checked, text) {
            // Render the new text now instead of after the next frame: a second click inside that window would be stale.
            lastMarkdown = new
            debounce?.cancel()  // a render of older text still waiting would otherwise land after this one
            Task { [weak self] in await self?.push(new) }
        } else {
            log.info("preview task toggle refused (line \(task.line), version \(version))")
            Task { [page] in _ = try? await page.callJavaScript("MacDown2Preview.resyncTasks()") }
        }
    }

    /// Quarto real render on (`active`) or off. On: the app's rendering stops at once and the page loads `url` when there is one
    /// (Quarto takes a few seconds to start); a new URL loads again. Off: `preview.html` is loaded afresh, the current text rendered and
    /// scrolled to the editor's line.
    func showExternal(active: Bool, url: URL?) {
        if active {
            if !externalActive {
                externalActive = true
                debounce?.cancel()
                pending = nil
                bridgeToken = nil
                pageLoaded = false
                loading = nil
                // The app's page goes at once: its checkboxes and editing would look as if they worked while nothing here takes them.
                // A blank page until Quarto's is there (the bar says starting / failed).
                if url == nil { show(URL(string: "about:blank")!) }
            }
            guard let url, url != externalURL else { return }
            externalURL = url
            show(url)
        } else {
            guard externalActive else { return }
            externalActive = false
            externalURL = nil
            documentRoot.externalOrigin = nil
            let line = editorLine?()
            Task { await reloadPage(line: line) }
        }

        func show(_ url: URL) {
            documentRoot.externalOrigin = url
            Task { [page] in
                do {
                    for try await _ in Self.load(url, in: page) {}
                } catch {
                    log.error("quarto page load failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Every load of the page goes through here (`Web/test/no-flicker.test.mjs` keeps it to this one place): `preview.html`, or
    /// Quarto's page during the real render.
    private static func load(_ url: URL, in page: WebPage) -> some AsyncSequence<WebPage.NavigationEvent, any Error> {
        page.load(URLRequest(url: url))
    }

    private func ensureLoaded() async -> Bool {
        if let loading { return await loading.value }
        loadedBlockingImages = RemoteContent.blocksImages(in: AppDefaults.store)
        let task = Task { [page] () -> Bool in
            do {
                for try await event in Self.load(PreviewAssetHandler.previewURL, in: page) where event == .finished {
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
        if zoomPercent != ViewZoom.actualSize { await applyZoom() }
    }

    /// A fresh token per load; the page keeps task checkboxes disabled (and editing off) until it has one.
    private func giveToken() async {
        let token = UUID().uuidString
        bridgeToken = token
        editChain.reset()
        do {
            _ = try await page.callJavaScript("MacDown2Preview.setTaskToken(token)", arguments: ["token": token])
        } catch {
            log.error("preview token failed: \(String(describing: error), privacy: .public)")
        }
        await applyEditing()
    }

    private func push(_ markdown: String) async {
        guard !externalActive else { return }
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
            // The page's preview edits this text contains (the page holds back a render that does not contain all of them yet). Recorded
            // as sent before the call: the page may report an edit on it before the call returns.
            let mark = editChain.mark(for: next)
            editChain.sent(version: version, text: next)
            do {
                // A chunk that fails to load is reported by `update` itself (the flavor is then unknown). The page forgets its block table
                // (`rebuild`) and takes the document folder (`base`) only when it applies the render, not when it holds it back.
                let result = try await page.callJavaScript(
                    "await MacDown2Preview.useFlavor(flavor).catch(() => {}); return MacDown2Preview.update(md, options, version, edit, rebuild, base)",
                    arguments: [
                        "md": next, "options": optionsJSON, "rebuild": rebuild, "flavor": flavorFiles, "base": base.map { $0 as Any } ?? NSNull(),
                        "version": version, "edit": mark.map { ["burst": $0.burst, "seq": $0.seq] as [String: Int] } ?? NSNull(),
                    ]
                )
                let elapsed = ContinuousClock.now - started
                // Render failures are reported over the bridge (`handle`); success carries outline/stats/blockCount/perf.
                let report = (result as? String).flatMap { try? JSONDecoder().decode(UpdateReport.self, from: Data($0.utf8)) }
                if report?.deferred == true {
                    // Held back by the page: it still shows the previous render (and more).
                    if rebuild { needsRebuild = true }
                    log.info("preview update held back by the page (edit in flight)")
                } else if report?.error == nil {
                    // A render that started before `clear()` / a document switch must not publish: its text is not the pane's any more.
                    if epoch == clearEpoch, let outline = report?.outline, let stats = report?.stats {
                        let decoded = PreviewMetadata(outline: outline, stats: stats)
                        if decoded != metadata { metadata = decoded }
                        editChain.landed(version: version, mark: mark)
                        if editorSelection != nil { await applyEditorSelection() }  // the render dropped the page's highlight
                    }
                    let perf = report?.perf
                    let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
                    let mode = perf?.mode ?? "?"
                    let jsRender = perf?.render ?? -1
                    let jsPatch = perf?.patch ?? -1
                    let jsSplit = perf?.split ?? -1
                    let jsApply = perf?.apply ?? -1
                    let blocks = report?.blockCount ?? -1
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
    @AppStorage(ViewZoom.key) private var zoomPercent = ViewZoom.actualSize
    @AppStorage(PreviewRenderKey.auto) private var autoRender = true
    private let renderSettings = RenderSettings.shared

    var body: some View {
        let mode = AlternatePreviewState.mode(of: flavor, fileURL: documentURL)
        let alternate = document.alternatePreview
        let external = mode != nil && alternate.isActive
        WebView(model.page)
            .webViewContentBackground(.hidden)
            .overlay(alignment: .top) { PreviewNotices(badge: external ? nil : flavor?.badge, hint: AppExtensions.disabledHint(for: documentURL)) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let mode, let documentURL {
                    AlternatePreviewBar(mode: mode, state: alternate, fileURL: documentURL, edited: document.editedFlag)
                }
            }
            // Quarto real render: Quarto's page instead of the app's while it is on (PLAN 4.6.2).
            .onChange(of: ExternalPage(active: external, url: external ? alternate.session?.url : nil), initial: true) { _, page in
                model.showExternal(active: page.active, url: page.url)
            }
            // The flavor lost its real render (switched off in Settings, file renamed away from .qmd): stop what it started.
            .onChange(of: mode == nil, initial: true) { _, gone in if gone, alternate.isActive { alternate.switchOff() } }
            // `initial`: the pane is gone while the window shows no document, and settings changed meanwhile must still arrive.
            .onChange(of: renderSettings.options, initial: true) { _, options in model.setOptions(options) }
            .onChange(of: "\(style)|\(followsSystem)", initial: true) { model.setStyle(id: style, followSystem: followsSystem) }
            .onChange(of: flavor?.id, initial: true) { model.setFlavor(flavor) }
            .onChange(of: blockRemoteImages, initial: true) { model.reloadForPolicyChange() }
            .onChange(of: previewEditing, initial: true) { _, on in model.setEditing(enabled: on) }
            .onChange(of: zoomPercent, initial: true) { _, percent in model.setZoom(percent: percent) }
            .onChange(of: autoRender, initial: true) { _, on in model.setAutoRender(on, text: document.text) }
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

private struct ExternalPage: Equatable {
    var active: Bool
    var url: URL?
}
