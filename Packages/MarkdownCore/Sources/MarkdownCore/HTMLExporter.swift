import Foundation
import UniformTypeIdentifiers
import WebAssets

/// Builds the standalone HTML file for File > Export > HTML and the page the print path renders. Pure: no WebView, no
/// file access of its own (images come through `ImageSource`).
public enum HTMLExporter {
    /// Reads a document-relative image path (already percent-decoded, no query or fragment) and returns its bytes and
    /// MIME type; nil when it cannot be read (the `<img>` is then left as written).
    public typealias ImageSource = @Sendable (_ relativePath: String) -> (data: Data, mime: String)?

    /// - Parameters:
    ///   - body: `RenderResult.html` of a render with `RenderOptions.forExport` (no source-line attributes).
    ///   - style: `(light, dark)` as returned by `PreviewStyles.resolve`.
    ///   - inlineImages: nil keeps `<img src>` as written; otherwise every document-relative one it can read becomes a
    ///     `data:` URI, so the file does not depend on the folder it came from.
    ///   - flavor: the document's flavor id; `stylesheets` are the extra WebAssets files it needs (e.g. `quarto-approx.css`).
    ///   - blockRemoteImages: adds a CSP with no network origin (`RemoteContent.printContentSecurityPolicy`), so printing or
    ///     saving a PDF fetches nothing: a remote `<img>` stays empty. For the print path; a saved HTML file would carry it too.
    ///   - userCSS: the text of the user's own stylesheet (`macdown2 render --css`), the last thing in the page so it wins.
    public static func document(
        body: String, title: String, style: (light: String, dark: String?) = PreviewStyles.resolve(id: PreviewStyles.defaultID, followSystem: false),
        inlineImages: ImageSource? = nil, flavor: String = "markdown", stylesheets: [String] = [], blockRemoteImages: Bool = false, userCSS: String? = nil
    ) -> String {
        var body = body
        if let inlineImages { body = inlineRelativeImages(in: body, source: inlineImages) }
        let math = body.contains(#"class="katex"#) ? "<style>\(katexCSS(fontURL: Self.fontDataURL))</style>\n" : ""
        // print.css (paper rules: no desk colour, wrapping code, page breaks) comes after everything that is the document's own
        // look, and the user's stylesheet after that.
        let extra = (stylesheets + ["print.css"]).map { "<style>\(asset($0))</style>\n" }.joined()
            + (userCSS.map { "<style>\(styleText($0))</style>\n" } ?? "")
        let csp = blockRemoteImages ? #"<meta http-equiv="Content-Security-Policy" content="\#(RemoteContent.printContentSecurityPolicy)">"# + "\n" : ""
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        \(csp)<title>\(escape(title))</title>
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

    /// The page runs no script of its own (KaTeX, highlighting and the style are all static; Mermaid is drawn by the app into the
    /// print page, or stays a code block), so a browser or viewer that opens the file is told to run none, whatever got into it.
    static let contentSecurityPolicy = "script-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"

    /// The same page with everything the user's settings decide read from `defaults` (the app's own preferences; nil = defaults):
    /// the preview style (and whether it follows the system) and "Block remote images". The one call File > Export, Print, PDF and
    /// `macdown2 render` make, so a switch in Settings reaches all of them.
    public static func document(
        body: String, title: String, defaults: UserDefaults?, inlineImages: ImageSource? = nil, flavor: String = "markdown",
        stylesheets: [String] = [], userCSS: String? = nil
    ) -> String {
        return document(
            body: body, title: title, style: PreviewStyles.resolve(defaults: defaults), inlineImages: inlineImages, flavor: flavor, stylesheets: stylesheets,
            blockRemoteImages: defaults.map(RemoteContent.blocksImages(in:)) ?? false, userCSS: userCSS
        )
    }

    // MARK: Style

    /// CSS as the content of a `<style>` element: nothing in it may end the element early.
    static func styleText(_ css: String) -> String {
        css.replacingOccurrences(of: "</style", with: #"<\/style"#, options: .caseInsensitive)
    }

    /// Light, fixed styles go in as they are. A dark style, or a light/dark pair, is for the screen only: paper always
    /// gets the light member (the dark styles keep light text, which would vanish on a white sheet once the print
    /// rules drop the background).
    static func styleCSS(_ style: (light: String, dark: String?)) -> String {
        let chosen = PreviewStyles.style(id: style.light)
        if style.dark == nil, chosen.appearance != "dark" { return css(style.light) }
        let screen = style.dark.map { "@media (prefers-color-scheme: light){\(css(style.light))}@media (prefers-color-scheme: dark){\(css($0))}" } ?? css(style.light)
        let printID = chosen.appearance == "dark" ? (chosen.pair ?? style.light) : style.light
        return "@media screen{\(screen)}@media print{\(css(printID))}"
    }

    /// The highlight.js theme the style names, then the style itself.
    private static func css(_ id: String) -> String {
        let style = PreviewStyles.style(id: id)
        return asset("hljs-themes/\(style.hljs).css") + asset("preview-styles/\(style.id).css")
    }

    /// KaTeX's CSS with each `url(fonts/<name>.woff2)` replaced by what `fontURL` returns for `<name>` (nil keeps the reference).
    /// Here the fonts become data URIs (one file, no `fonts/` folder to lose; ~350 kB, so only when the document has math); Quick
    /// Look points them at its attachments.
    static func katexCSS(fontURL: (_ name: String) -> String?) -> String {
        fontReference.replacingMatches(in: asset("katex/katex.min.css")) { m in fontURL(m[1]).map { "url(\($0))" } ?? m[0] }
    }

    private static let fontReference = try! NSRegularExpression(pattern: #"url\(fonts/([^)]+)\.woff2\)"#)

    private static func fontDataURL(_ name: String) -> String? {
        WebAssets.url("katex/fonts/\(name).woff2").flatMap { try? Data(contentsOf: $0) }.map { "data:font/woff2;base64,\($0.base64EncodedString())" }
    }

    static func asset(_ name: String) -> String {
        WebAssets.url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Images

    /// Reads document-relative images from `directory` for `document(inlineImages:)`, with the same containment rules as the
    /// preview's `macdown2-res://doc/` handler (nothing outside the document folder, no non-image files); nil without a folder.
    public static func imageSource(directory: URL?) -> ImageSource {
        { path in
            guard case .file(let file) = DocumentFileResolver.resolve(path: "/" + path, root: directory),
                  let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
                  let data = try? Data(contentsOf: file)
            else { return nil }
            return (data, mime)
        }
    }

    private static let imgSrc = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc=)(["'])(.*?)\2"#, options: [.dotMatchesLineSeparators])

    static func inlineRelativeImages(in html: String, source: ImageSource) -> String {
        imgSrc.replacingMatches(in: html) { m in
            guard let path = relativePath(of: m[3]), let image = source(path) else { return m[0] }
            return "\(m[1])\(m[2])data:\(image.mime);base64,\(image.data.base64EncodedString())\(m[2])"
        }
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
