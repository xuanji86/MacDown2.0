import Foundation
import UniformTypeIdentifiers
import WebAssets

/// The static HTML page the Quick Look extension hands to `QLPreviewReply`. Lives here (not in the extension target)
/// so `swift test` covers it; the extension itself is only glue (read file, call `make`, wrap the reply).
///
/// Quick Look shows the page in a host web view, so the page must stand on its own:
/// - no scripts: KaTeX is already static HTML from `renderToString`, Mermaid is not rendered (it stays a code block);
/// - raw HTML in the document is escaped, because the host ran inline `<script>` and ignored a `<meta>` CSP in testing
///   (macOS 27.2), so an untrusted `.md` must not be able to inject markup;
/// - relative `<img>` are read from the document's folder (the extension has a read-only sandbox exception for that, PLAN 4.9;
///   same containment rules as the app, `DocumentFileResolver`) and travel as `cid:` attachments like the KaTeX fonts; an image
///   that is missing, outside the folder, not an image or over the size caps stays a text placeholder;
/// - no network: Quick Look must not fetch anything just because a file was previewed, so a remote image (`http(s)`, `//host`,
///   anything with a scheme except `data:`) becomes the same text placeholder, `srcset` and CSS `url()` in inline styles are
///   dropped, and the page carries a CSP with no network origin (a backstop; the host may ignore it, the rewriting does not);
/// - links: only `http`, `https`, `mailto` and in-page `#anchors` stay links. `ssh://`, `file:` and every other scheme (and
///   relative links, which resolve against nothing here) become plain text, as `LinkPolicy` refuses them in the app.
public struct QuickLookPage: Sendable {
    public struct Attachment: Sendable, Hashable {
        /// Referenced from the HTML as `cid:<id>`.
        public let id: String
        public let data: Data
        public let fileExtension: String
    }

    public var html: String
    public var attachments: [Attachment]
    public var truncated: Bool

    /// Documents beyond this many bytes are cut at a line boundary (S5 measured the render cost; see PLAN appendix A item 4).
    public static let maxBytes = 256 * 1024
    /// Per-image and per-page caps for local images; beyond them the placeholder stays. Attachments sit in memory until the reply is sent.
    public static let maxImageBytes = 10 * 1024 * 1024
    public static let maxTotalImageBytes = 50 * 1024 * 1024

    /// `data` is what the extension read from the file: at most `maxBytes + 1` bytes (the extra byte only tells us there is more).
    public static func make(
        data: Data,
        utType: String,
        renderer: some MarkdownRenderer,
        manifest: FlavorManifest? = try? .bundled(),
        documentDirectory: URL? = nil,  // nil = no local images (placeholders)
        defaults: UserDefaults? = nil,  // the app's preferences (render switches, preview style); nil/absent keys = defaults
        isEnabled: ((String) -> Bool)? = nil  // extension switches; default reads `defaults`, an unset switch counts as on
    ) async throws -> QuickLookPage {
        let (source, truncated) = decode(data)
        let isEnabled = isEnabled ?? { defaults?.object(forKey: $0) as? Bool ?? true }
        var options = defaults.map { RenderPreferences(defaults: $0).options } ?? RenderOptions()
        options.allowRawHTML = false  // whatever the app's setting says: the host runs scripts (see above)
        options.headingAnchors = true
        var styleSheets: [String] = []
        if let manifest {
            let (flavor, chunks) = manifest.resolve(utType: utType, isEnabled: isEnabled)
            options.flavor = flavor
            options.renderChunks = chunks
            styleSheets = manifest.entries[flavor]?.stylesheets ?? []
        }
        let result = try await renderer.render(source, options: options)
        var body = HTMLExporter.stripSourceLines(result.html)
        var attachments: [Attachment] = []
        var loaded: [String: String?] = [:]  // path -> cid (nil = refused), so a repeated image is read once
        var imageBytes = 0
        body = replacing(#"<img\b[^>]*>"#, in: body) { m in
            let src = Self.attribute("src", in: m[0]) ?? "", alt = Self.attribute("alt", in: m[0]) ?? ""
            if src.hasPrefix("data:") { return m[0] }  // inline bytes, nothing to fetch
            if let path = HTMLExporter.relativePath(of: src), let directory = documentDirectory {
                if let known = loaded[path] {
                    if let id = known { return #"<img src="cid:\#(id)" alt="\#(alt)">"# }
                } else if let image = Self.readImage(path, in: directory, budget: maxTotalImageBytes - imageBytes) {
                    let id = "md2-img-\(attachments.count)"
                    imageBytes += image.data.count
                    attachments.append(Attachment(id: id, data: image.data, fileExtension: image.fileExtension))
                    loaded[path] = id
                    return #"<img src="cid:\#(id)" alt="\#(alt)">"#
                } else {
                    loaded[path] = .some(nil)
                }
            }
            return #"<span class="md2-ql-note">[\#(Strings.image): \#(alt.isEmpty ? src : alt)]</span>"#
        }
        body = neutralizeLinks(removeNetworkReferences(body))

        let style = PreviewStyles.resolve(
            id: defaults?.string(forKey: PreviewStyles.styleKey) ?? PreviewStyles.defaultID,
            followSystem: defaults?.bool(forKey: PreviewStyles.followsSystemKey) ?? false
        )
        var css = [HTMLExporter.styleCSS(style)]
        css += styleSheets.map(asset)
        css.append(Self.noteCSS)
        if body.contains("katex") {
            let fonts = (try? FileManager.default.contentsOfDirectory(at: WebAssets.url("katex/fonts")!, includingPropertiesForKeys: nil)) ?? []
            attachments += fonts.filter { $0.pathExtension == "woff2" }.compactMap { url in
                (try? Data(contentsOf: url)).map { Attachment(id: url.deletingPathExtension().lastPathComponent, data: $0, fileExtension: "woff2") }
            }
            css.append(replacing(#"url\(fonts/([^)]+)\.woff2\)"#, in: asset("katex/katex.min.css")) { "url(cid:\($0[1]))" })
        }

        let banner = truncated ? #"<p class="md2-ql-note md2-ql-truncated">\#(Strings.truncated)</p>"# : ""
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)"><meta name="color-scheme" content="\(colorScheme(style))">
        <style>\(css.joined(separator: "\n"))</style></head>
        <body><article id="doc" data-flavor="\(options.flavor.rawValue)">\(banner)\(body)\(banner)</article></body></html>
        """
        return QuickLookPage(html: html, attachments: attachments, truncated: truncated)
    }

    /// No network origin at all: images and fonts come from `cid:` attachments or `data:`, styles are inline.
    public static let contentSecurityPolicy = "default-src 'none'; img-src cid: data:; font-src cid: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    // MARK: - Internals

    /// The value of a double-quoted attribute in one tag, still HTML-escaped as the renderer wrote it.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\s\#(name)\s*=\s*"([^"]*)""#, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: match.range(at: 1))
    }

    /// Drops what could make the host fetch something: `srcset` and `poster` attributes, `<source>`/`<link>` tags, and `style`
    /// attributes that could hold a CSS `url()`. The renderer escapes raw HTML, so none of these should be here; this is the
    /// second line behind that and the CSP. A style is judged by its text: `url(`, `image-set`, `@import`, a backslash escape
    /// or an HTML entity (which the parser decodes before the CSS sees it) is enough to drop it.
    ///
    /// Only real tags are touched: text and code never contain a literal `<` (the renderer escapes it), so `<…>` is exactly
    /// a tag, and inside one the attributes are walked one by one, so a quoted value (`alt="use srcset=x"`) is not rescanned.
    static func removeNetworkReferences(_ html: String) -> String {
        replacing(#"<[A-Za-z][^>]*>"#, in: html) { tag in
            let tag = tag[0]
            if tag.range(of: #"^<(?:source|link)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return "" }
            return replacing(#"\s+([^\s=/>"']+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?"#, in: tag) { attribute in
                let name = attribute[1].lowercased()
                if name == "srcset" || name == "poster" { return "" }
                guard name == "style" else { return attribute[0] }
                let value = attribute[0].lowercased()
                let risky = ["url(", "image-set", "@import", "\\", "&", "src(", "expression"].contains { value.contains($0) }
                return risky ? "" : attribute[0]
            }
        }
    }

    /// Only `http(s)://host`, `mailto:` and `#anchor` links stay live (what `LinkPolicy` lets through, minus files); any other
    /// `<a href>` becomes a `<span>` with the same content. The test is an allow-list on the raw attribute, so an
    /// entity-encoded or whitespace-padded scheme does not match and is neutralised too.
    static func neutralizeLinks(_ html: String) -> String {
        var neutralized = false  // anchors do not nest, so one flag pairs each `</a>` with its opening tag
        return replacing(#"<a\b[^>]*>|</a\s*>"#, in: html) { m in
            if m[0].hasPrefix("</") { defer { neutralized = false }; return neutralized ? "</span>" : m[0] }
            guard let href = attribute("href", in: m[0]) else { neutralized = false; return m[0] }  // `<a name>`: nothing to follow
            let allowed = href.hasPrefix("#") || href.range(of: #"^(?:https?://[^/?#\s]|mailto:)"#, options: [.regularExpression, .caseInsensitive]) != nil
            neutralized = !allowed
            return allowed ? m[0] : "<span>"
        }
    }

    /// A regular image file inside `directory` (`DocumentFileResolver` rules), at most `maxImageBytes` and `budget`. The read is
    /// bounded, not just the size attribute, so a file that grows meanwhile cannot slip through.
    private static func readImage(_ path: String, in directory: URL, budget: Int) -> (data: Data, fileExtension: String)? {
        guard case .file(let file) = DocumentFileResolver.resolve(path: "/" + path, root: directory),
              UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let limit = min(maxImageBytes, budget)
        guard limit > 0, let data = try? handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else { return nil }
        return (data, file.pathExtension.lowercased())
    }

    private static let noteCSS = """
    .md2-ql-note { color: var(--fg-muted); font-style: italic; }
    .md2-ql-truncated { padding: 8px 12px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg-subtle); font-style: normal; }
    """

    /// What the page may be drawn in: a dark style or a light/dark pair needs the host to allow dark.
    private static func colorScheme(_ style: (light: String, dark: String?)) -> String {
        style.dark != nil || PreviewStyles.all.first { $0.id == style.light }?.appearance == "dark" ? "light dark" : "light"
    }

    private static func asset(_ name: String) -> String {
        WebAssets.url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// UTF-8 (a UTF-16 byte-order mark switches to UTF-16). When the file is longer than `maxBytes` the text is cut at the
    /// last full line. lazy: no charset sniffing beyond that; upgrade = `NSString.stringEncoding(for:)`.
    static func decode(_ data: Data) -> (text: String, truncated: Bool) {
        let truncated = data.count > maxBytes
        var bytes = truncated ? data.prefix(maxBytes) : data
        if truncated, let newline = bytes.lastIndex(of: 0x0A) { bytes = bytes[..<newline] }  // never cut a multibyte character in half
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: Data(bytes), encoding: .utf16) { return (text, truncated) }
        let text = String(decoding: bytes, as: UTF8.self)
        return (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text, truncated)
    }

    /// Regex replace; the closure gets the match and its capture groups (`[0]` is the whole match).
    private static func replacing(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) })
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    private enum Strings {
        private static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        static let image = zh ? "图片" : "image"
        static let truncated = zh ? "文档过大，仅显示开头部分。在 MacDown2.0 中打开查看全文。" : "Document too large, showing the beginning only. Open in MacDown2.0 to view the full text."
    }
}
