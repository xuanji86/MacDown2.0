import AppKit
import MarkdownCore
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "copy-html")

/// Edit > Copy HTML: the rendered document as HTML on the pasteboard (as `public.html` for rich targets and as plain
/// text, the HTML source, for code editors; the original MacDown copied the source).
@MainActor
enum CopyHTML {
    private static var renderer: Task<JSCRenderer, any Error>?

    /// The document as rendered HTML, with the current Markdown / Rendering settings
    /// unless `options` says otherwise. One renderer serves both copy and export, and both are output that leaves the app: script,
    /// frames, event handlers and script URLs a hostile document carries are removed (the preview has a CSP instead).
    /// `fileURL` decides the flavor (a .qmd renders with the Quarto chunk while that extension is on) and where includes are read.
    static func render(_ markdown: String, options: RenderOptions = RenderSettings.current, fileURL: URL? = nil) async throws -> String {
        // The creation itself is kept while it runs, so uses that start before the first one finishes share one renderer.
        let creation = self.renderer ?? Task { try await JSCRenderer.makeOffMain() }
        self.renderer = creation
        let renderer: JSCRenderer
        do { renderer = try await creation.value } catch {
            if self.renderer == creation { self.renderer = nil }  // a failed creation is tried again by the next use
            throw error
        }
        return try await renderer.render(markdown, options: AppExtensions.renderOptions(options, markdown: markdown, fileURL: fileURL).forExport).html
    }

    static func copy(_ markdown: String, fileURL: URL? = nil, to pasteboard: NSPasteboard = .general) async {
        do {
            let html = try await render(markdown, fileURL: fileURL)
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            pasteboard.setString(html, forType: .string)
        } catch {
            log.error("copy html failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }
}

extension JSCRenderer {
    /// A renderer made off the main actor: a JSContext created on the main thread puts its timers on the main run loop, which then waits
    /// on the VM lock while a large render holds it (and loading the bundle would hold the main thread too).
    static func makeOffMain() async throws -> JSCRenderer {
        try await Task.detached { try JSCRenderer() }.value
    }
}
