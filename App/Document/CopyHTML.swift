import AppKit
import MarkdownCore
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "copy-html")

/// Edit > Copy HTML: the rendered document as HTML on the pasteboard (as `public.html` for rich targets and as plain
/// text, the HTML source, for code editors; the original MacDown copied the source).
@MainActor
enum CopyHTML {
    private static var renderer: JSCRenderer?

    /// The document as rendered HTML, with the current Markdown / Rendering settings
    /// unless `options` says otherwise. One renderer serves both copy and export, and both are output that leaves the app: script,
    /// frames, event handlers and script URLs a hostile document carries are removed (the preview has a CSP instead).
    /// `fileURL` decides the flavor (a .qmd renders with the Quarto chunk while that extension is on) and where includes are read.
    static func render(_ markdown: String, options: RenderOptions = RenderSettings.current, fileURL: URL? = nil) async throws -> String {
        let renderer = try renderer ?? JSCRenderer()
        self.renderer = renderer
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
