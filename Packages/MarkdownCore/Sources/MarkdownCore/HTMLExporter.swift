import Foundation
import WebAssets

/// Builds the standalone HTML file for File > Export > HTML and the page the print path renders. Pure: no WebView, no
/// file access of its own (images come through `ImageSource`).
public enum HTMLExporter {
    /// Reads a document-relative image path (already percent-decoded, no query or fragment) and returns its bytes and
    /// MIME type; nil when it cannot be read (the `<img>` is then left as written).
    public typealias ImageSource = @Sendable (_ relativePath: String) -> (data: Data, mime: String)?

    /// The renderer tags blocks with source lines for scroll sync; that is noise in an exported file or on a clipboard.
    public static func stripSourceLines(_ html: String) -> String {
        html.replacingOccurrences(of: #" data-line(?:-end)?="\d+""#, with: "", options: .regularExpression)
    }

    /// - Parameters:
    ///   - body: `RenderResult.html`.
    ///   - style: `(light, dark)` as returned by `PreviewStyles.resolve`.
    ///   - inlineImages: nil keeps `<img src>` as written; otherwise every document-relative one it can read becomes a
    ///     `data:` URI, so the file does not depend on the folder it came from.
    ///   - flavor: the document's flavor id; `stylesheets` are the extra WebAssets files it needs (e.g. `quarto-approx.css`).
    public static func document(
        body: String, title: String, style: (light: String, dark: String?) = PreviewStyles.resolve(id: PreviewStyles.defaultID, followSystem: false),
        inlineImages: ImageSource? = nil, flavor: String = "markdown", stylesheets: [String] = []
    ) -> String {
        var body = stripSourceLines(body)
        if let inlineImages { body = inlineRelativeImages(in: body, source: inlineImages) }
        let math = body.contains(#"class="katex"#) ? "<style>\(katexCSS())</style>\n" : ""
        let extra = stylesheets.map { "<style>\(asset($0))</style>\n" }.joined()
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(styleCSS(style))</style>
        \(math)\(extra)</head>
        <body>
        <article id="doc" data-flavor="\(escape(flavor))">
        \(body)
        </article>
        </body>
        </html>

        """
    }

    // MARK: Style

    /// Light, fixed styles go in as they are. A dark style, or a light/dark pair, is for the screen only: paper always
    /// gets the light member (the dark styles keep light text, which would vanish on a white sheet once the print
    /// rules drop the background).
    static func styleCSS(_ style: (light: String, dark: String?)) -> String {
        let chosen = PreviewStyles.all.first { $0.id == style.light }
        if style.dark == nil, chosen?.appearance != "dark" { return css(style.light) }
        let screen = style.dark.map { "@media (prefers-color-scheme: light){\(css(style.light))}@media (prefers-color-scheme: dark){\(css($0))}" } ?? css(style.light)
        let printID = chosen?.appearance == "dark" ? (chosen?.pair ?? style.light) : style.light
        return "@media screen{\(screen)}@media print{\(css(printID))}"
    }

    /// The highlight.js theme the style names, then the style itself.
    private static func css(_ id: String) -> String {
        let style = PreviewStyles.all.first { $0.id == id } ?? PreviewStyles.all.first { $0.id == PreviewStyles.defaultID }!
        return asset("hljs-themes/\(style.hljs).css") + asset("preview-styles/\(style.id).css")
    }

    /// KaTeX CSS with its fonts as data URIs: one file, no `fonts/` folder to lose. Costs ~350 kB, so only when the
    /// document has math.
    private static func katexCSS() -> String {
        let css = asset("katex/katex.min.css")
        guard let fonts = try? NSRegularExpression(pattern: #"url\(fonts/([^)]+\.woff2)\)"#) else { return css }
        var out = ""
        var last = css.startIndex
        for match in fonts.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            let whole = Range(match.range, in: css)!, name = String(css[Range(match.range(at: 1), in: css)!])
            out += css[last..<whole.lowerBound]
            if let url = WebAssets.url("katex/fonts/\(name)"), let data = try? Data(contentsOf: url) {
                out += "url(data:font/woff2;base64,\(data.base64EncodedString()))"
            } else {
                out += css[whole]
            }
            last = whole.upperBound
        }
        return out + css[last...]
    }

    private static func asset(_ name: String) -> String {
        WebAssets.url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Images

    private static let imgSrc = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc=)(["'])(.*?)\2"#, options: [.dotMatchesLineSeparators])

    static func inlineRelativeImages(in html: String, source: ImageSource) -> String {
        var out = ""
        var last = html.startIndex
        for match in imgSrc.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let whole = Range(match.range, in: html)!
            let src = String(html[Range(match.range(at: 3), in: html)!])
            out += html[last..<whole.lowerBound]
            if let path = relativePath(of: src), let image = source(path) {
                let prefix = html[Range(match.range(at: 1), in: html)!], quote = html[Range(match.range(at: 2), in: html)!]
                out += "\(prefix)\(quote)data:\(image.mime);base64,\(image.data.base64EncodedString())\(quote)"
            } else {
                out += html[whole]
            }
            last = whole.upperBound
        }
        return out + html[last...]
    }

    /// `src` as an attribute value → the file path it names next to the document; nil for absolute URLs (any scheme),
    /// root-relative paths and fragments.
    static func relativePath(of src: String) -> String? {
        let src = src.replacingOccurrences(of: "&amp;", with: "&")
        guard !src.isEmpty, !src.hasPrefix("/"), !src.hasPrefix("#"), src.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) == nil else { return nil }
        let path = String(src.prefix { $0 != "?" && $0 != "#" })
        return path.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
