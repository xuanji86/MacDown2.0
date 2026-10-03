import AppKit
import MarkdownCore
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "copy-html")

/// Edit > Copy HTML: the rendered document as HTML on the pasteboard (as `public.html` for rich targets and as plain
/// text, the HTML source, for code editors; the original MacDown copied the source).
@MainActor
enum CopyHTML {
    private static var renderer: JSCRenderer?

    static func copy(_ markdown: String, to pasteboard: NSPasteboard = .general) async {
        do {
            let renderer = try renderer ?? JSCRenderer()
            self.renderer = renderer
            let html = clean(try await renderer.render(markdown, options: RenderOptions()).html)
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            pasteboard.setString(html, forType: .string)
        } catch {
            log.error("copy html failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// The renderer tags blocks with source lines for scroll sync; that is noise on a clipboard.
    static func clean(_ html: String) -> String {
        html.replacingOccurrences(of: #" data-line(?:-end)?="\d+""#, with: "", options: .regularExpression)
    }
}
