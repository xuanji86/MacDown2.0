import AppKit
import MarkdownCore
import OSLog
import WebAssets
import WebKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "print")

/// Paper output for the exported HTML. `WebPage` has no print or pagination API (its `exported(as: .pdf)` is one tall
/// strip as wide as the view, PLAN §4.7), so this lays the page out in an offscreen `WKWebView` and lets AppKit
/// paginate it through `printOperation(with:)`: paper size and margins from an `NSPrintInfo`, `@media print` rules
/// applied (print.css), `break-inside` honoured, `#anchor` links kept as links inside the PDF.
///
/// The web view sits in a borderless window that is never shown: `WKWebView`'s printing view needs a window to lay out
/// in, and without one the operation never finishes paginating.
///
/// Headless: nothing here needs the app's UI. A command-line process (`macdown2 render --export pdf`) calls
/// `becomeHeadless()` once and then `pdf(html:setup:)`; it needs a login session (the window server), like any AppKit
/// process, but no Dock tile, no menu bar, no visible window.
@MainActor
public final class PrintPage: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?
    /// The one navigation this page may make is the load of its own HTML; every later one (a meta refresh, whatever else) is cancelled.
    private var loading = false

    public override init() {
        let configuration = WKWebViewConfiguration()
        // The page is the user's own document, possibly with raw HTML: nothing in it needs to run to be printed.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// For a process that is not the app: no Dock icon, no menu bar, never frontmost. Call before the first `PrintPage`.
    public static func becomeHeadless() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// The whole job for a file: `html` (an exported page, see `HTMLExporter.document`) as a paginated PDF.
    public static func pdf(html: String, setup: PageSetup) async throws -> Data {
        try await pdf(html: html, setup: setup, removingAutoNavigation: true)
    }

    static func pdf(html: String, setup: PageSetup, removingAutoNavigation: Bool, settle: Duration = .zero) async throws -> Data {
        let page = PrintPage()
        try await page.load(html: html, removingAutoNavigation: removingAutoNavigation)
        try await Task.sleep(for: settle)  // tests: time for a meta refresh to fire before the job starts
        let url = FileManager.default.temporaryDirectory.appending(path: "macdown2-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = printInfo(setup, base: NSPrintInfo(dictionary: [:]))
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        guard await page.run(info: info, panel: false) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the print system could not write the PDF"]) }
        return try Data(contentsOf: url)
    }

    /// `<meta http-equiv="refresh">`: JavaScript being off does not stop it, and it would turn the PDF into somebody else's page.
    private static let autoNavigation = /<meta\b[^>]*\bhttp-equiv\s*=\s*["']?\s*refresh\b[^>]*>/.ignoresCase()

    /// Returns once the page, its images and its fonts have loaded, so the first page is not printed half-drawn.
    /// Two guards keep the printout the document's own: auto-navigation markup is removed before the load (exported pages have
    /// none, `RenderOptions.forExport` sanitizes them; this is for any other caller), and the navigation delegate cancels every
    /// navigation after the first.
    public func load(html: String) async throws {
        try await load(html: html, removingAutoNavigation: true)
    }

    func load(html: String, removingAutoNavigation: Bool) async throws {
        let html = removingAutoNavigation ? html.replacing(Self.autoNavigation, with: "") : html
        loading = true
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        await drawDiagrams()
        await keepHeadingsWithTheirText()
        _ = try? await webView.callAsyncJavaScript("await document.fonts.ready", contentWorld: .defaultClient)
    }

    /// Mermaid blocks arrive as plain code blocks (`pre.mermaid-source`, see `HTMLExporter`). The page itself runs no
    /// scripts, so the app injects mermaid.chunk.js into its own content world (`allowsContentJavaScript` only stops
    /// the page's scripts) and waits until every diagram is drawn, so pagination sees the final heights. Light theme:
    /// paper is white. A failed diagram stays a code block with the error under it; a missing chunk leaves all of them.
    private func drawDiagrams() async {
        let world = WKContentWorld.defaultClient
        guard let count = try? await webView.callAsyncJavaScript("return document.querySelectorAll('pre.mermaid-source').length", contentWorld: world) as? Int, count > 0,
              let chunk = WebAssets.url("mermaid.chunk.js"), let source = try? String(contentsOf: chunk, encoding: .utf8)
        else { return }
        do {
            _ = try await webView.evaluateJavaScript(source, in: nil, contentWorld: world)
            _ = try await webView.callAsyncJavaScript("await MacDown2Mermaid.renderAll(document, false)", contentWorld: world)
        } catch {
            log.error("Mermaid diagrams not drawn for printing: \(String(describing: error), privacy: .public)")
        }
    }

    /// WebKit's printing does not honour `break-after: avoid`, so a heading can end up alone at the foot of a page. Until it does,
    /// each heading (and the headings stacked on it) goes into a `div.md2-keep` together with the block that follows, and print.css
    /// keeps that div whole. Only when that block is short (500 characters, 13 table rows): a long one would push the heading
    /// to the next page and leave a hole behind, and one taller than a page is split anyway.
    // lazy: character count stands in for height (the layout here is not the printed one); upgrade = measure after pagination.
    private func keepHeadingsWithTheirText() async {
        let script = """
        for (const heading of document.querySelectorAll('#doc h1, #doc h2, #doc h3, #doc h4, #doc h5, #doc h6')) {
          if (heading.parentElement.classList.contains('md2-keep')) continue;
          const group = [heading];
          let next = heading.nextElementSibling;
          while (next && /^H[1-6]$/.test(next.tagName)) { group.push(next); next = next.nextElementSibling; }
          if (!next || next.classList.contains('md2-page-break') || next.textContent.length > 500 || next.querySelectorAll('tr').length > 13) continue;
          group.push(next);
          const wrapper = document.createElement('div');
          wrapper.className = 'md2-keep';
          heading.before(wrapper);
          wrapper.append(...group);
        }
        """
        do { _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) } catch {
            log.error("Headings not kept with their text for printing: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Paper

    /// `base` (the system print settings: printer, copies, scaling) with paper, orientation and margins from `setup`.
    public static func printInfo(_ setup: PageSetup, base: NSPrintInfo = .shared) -> NSPrintInfo {
        let info = base.copy() as! NSPrintInfo
        let size = setup.paper.size
        info.paperSize = NSSize(width: size.width, height: size.height)  // portrait; the orientation turns it
        info.orientation = setup.orientation == .landscape ? .landscape : .portrait
        info.topMargin = setup.top
        info.bottomMargin = setup.bottom
        info.leftMargin = setup.left
        info.rightMargin = setup.right
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// The other direction, for Page Setup…: what the user chose in the system panel, as far as `PageSetup` can say it.
    /// A paper that is not one of ours keeps `previous.paper`.
    public static func pageSetup(from info: NSPrintInfo, previous: PageSetup) -> PageSetup {
        var setup = previous
        setup.orientation = info.orientation == .landscape ? .landscape : .portrait
        let side = (info.paperSize.width, info.paperSize.height)
        let portrait = setup.orientation == .portrait ? side : (side.1, side.0)  // `paperSize` follows the orientation
        if let paper = PageSetup.Paper.allCases.first(where: { abs($0.size.width - portrait.0) < 3 && abs($0.size.height - portrait.1) < 3 }) { setup.paper = paper }
        func margin(_ value: CGFloat) -> Double { min(max(Double(value), PageSetup.marginRange.lowerBound), PageSetup.marginRange.upperBound) }
        setup.top = margin(info.topMargin)
        setup.bottom = margin(info.bottomMargin)
        setup.left = margin(info.leftMargin)
        setup.right = margin(info.rightMargin)
        return setup
    }

    /// Runs the print job and returns whether it completed. With `panel` the system print dialog opens first, as a sheet
    /// on `sheetWindow` (the document window); without it the job goes straight to `info`'s destination.
    public func run(info: NSPrintInfo, panel: Bool, sheetWindow: NSWindow? = nil) async -> Bool {
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = panel
        operation.showsProgressPanel = false
        return await withCheckedContinuation { continuation in
            let finish = Finish(continuation)
            // The operation keeps its delegate only weakly; `finish` stays alive through the callback context.
            operation.runModal(
                for: panel ? (sheetWindow ?? window) : window, delegate: finish,
                didRun: #selector(Finish.printOperationDidRun(_:success:contextInfo:)), contextInfo: Unmanaged.passRetained(finish).toOpaque()
            )
        }
    }

    private final class Finish: NSObject {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            continuation?.resume(returning: success)
            continuation = nil
            if let contextInfo { Unmanaged<Finish>.fromOpaque(contextInfo).release() }
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard loading else { return .cancel }
        loading = false
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }

    private func finish(_ error: (any Error)?) {
        guard let loaded else { return }
        self.loaded = nil
        if let error { loaded.resume(throwing: error) } else { loaded.resume() }
    }
}
