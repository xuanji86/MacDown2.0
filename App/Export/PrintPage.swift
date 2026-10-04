import AppKit
import OSLog
import WebAssets
import WebKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "print")

/// Paper output for the exported HTML. `WebPage` has no print or pagination API (its `exported(as: .pdf)` is one tall
/// strip as wide as the view, PLAN §4.7), so this lays the page out in an offscreen `WKWebView` and lets AppKit
/// paginate it through `printOperation(with:)`: paper size and margins from an `NSPrintInfo`, `@media print` rules
/// applied, `break-inside` honoured.
///
/// The web view sits in a borderless window that is never shown: `WKWebView`'s printing view needs a window to lay out
/// in, and without one the operation never finishes paginating.
@MainActor
final class PrintPage: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        // The page is the user's own document, possibly with raw HTML: nothing in it needs to run to be printed.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Returns once the page, its images and its fonts have loaded, so the first page is not printed half-drawn.
    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        await drawDiagrams()
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

    /// The system page setup (paper, orientation) with at least `minimumMargin` points on every side; a bigger margin
    /// the user chose in Page Setup stays.
    static func printInfo(minimumMargin: Double = 54, base: NSPrintInfo = .shared) -> NSPrintInfo {
        let info = base.copy() as! NSPrintInfo
        info.topMargin = max(info.topMargin, minimumMargin)
        info.bottomMargin = max(info.bottomMargin, minimumMargin)
        info.leftMargin = max(info.leftMargin, minimumMargin)
        info.rightMargin = max(info.rightMargin, minimumMargin)
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Runs the print job and returns whether it completed. With `panel` the system print dialog opens first, as a sheet
    /// on `sheetWindow` (the document window); without it the job goes straight to `info`'s destination.
    func run(info: NSPrintInfo, panel: Bool, sheetWindow: NSWindow? = nil) async -> Bool {
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }

    private func finish(_ error: (any Error)?) {
        guard let loaded else { return }
        self.loaded = nil
        if let error { loaded.resume(throwing: error) } else { loaded.resume() }
    }
}
