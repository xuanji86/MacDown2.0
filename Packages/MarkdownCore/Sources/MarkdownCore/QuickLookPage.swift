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
///   that is missing, outside the folder, not an image or over the size caps stays a text placeholder.
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
        body = replacing(#"<img src="([^"]*)" alt="([^"]*)"[^>]*>"#, in: body) { m in
            let src = m[1], alt = m[2]
            if src.hasPrefix("//") || src.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return m[0] }
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
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="\(colorScheme(style))">
        <style>\(css.joined(separator: "\n"))</style></head>
        <body><article id="doc" data-flavor="\(options.flavor.rawValue)">\(banner)\(body)\(banner)</article></body></html>
        """
        return QuickLookPage(html: html, attachments: attachments, truncated: truncated)
    }

    // MARK: - Internals

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
