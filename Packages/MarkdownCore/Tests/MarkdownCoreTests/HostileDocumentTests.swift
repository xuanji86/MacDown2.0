import Foundation
import Testing
import WebAssets
@testable import MarkdownCore

// Fixtures/own/hostile.md: script, event handlers, javascript:/data:/file: links, frames, SVG, meta refresh, forms, traversal
// in image paths, links to programs. The preview page and its navigation policy are covered by Web/test/hostile.test.mjs and
// LinkPolicyTests; here: the paths that show a document without the preview page (Quick Look, which runs in a host that
// ignores a <meta> CSP) and the renderer itself.

private func hostile() throws -> String {
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures/own/hostile.md")
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func quickLookPageContainsNoLiveMarkupFromAHostileDocument() async throws {
    let p = try await QuickLookPage.make(data: Data(hostile().utf8), utType: "net.daringfireball.markdown", renderer: JSCRenderer(), documentDirectory: nil)
    let article = String(p.html[p.html.range(of: "<article")!.lowerBound...])
    for tag in ["<script", "<iframe", "<frame", "<object", "<embed", "<svg", "<math", "<meta", "<base", "<form", "<link", "<style", "<body", "<video", "<input", "<details"] {
        #expect(!article.contains(tag), "\(tag) survived")
    }
    // an `on…=` attribute in a real tag; quoted attribute values are dropped first (a title may contain the escaped text)
    for tag in article.matches(of: /<[a-zA-Z][^>]*>/) {
        let unquoted = String(tag.output).replacing(/"[^"]*"/, with: "\"\"")
        #expect(unquoted.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil, "an event handler attribute survived in \(tag.output)")
    }
    #expect(article.range(of: #"<a [^>]*href="(javascript|data|file|blob):"#, options: [.regularExpression, .caseInsensitive]) == nil, "a dangerous link survived")
    #expect(article.range(of: #"<img [^>]*src="(file|javascript):"#, options: [.regularExpression, .caseInsensitive]) == nil)
    #expect(p.attachments.isEmpty, "no image of a hostile document is read from disk without a document folder")
}

@Test func hostileImagePathsNeverBecomeAttachments() async throws {
    // A document folder with a secret next to it: `../secret.png` and friends must stay placeholders.
    let t = try ResolverTree(); defer { t.remove() }
    try Data("secret".utf8).write(to: t.sandbox.appending(path: "secret.png"))
    let p = try await QuickLookPage.make(data: Data(hostile().utf8), utType: "net.daringfireball.markdown", renderer: JSCRenderer(), documentDirectory: t.doc)
    #expect(p.attachments.isEmpty)
    #expect(!p.html.contains("cid:md2-img"))
}

@Test func hostileDocumentRendersWithEveryOptionAndKeepsItsBlockMap() async throws {
    var options = RenderOptions()
    options.extensions = Set(MarkdownExtension.allCases)
    options.allowRawHTML = true
    let r = try await JSCRenderer().render(try hostile(), options: options)
    #expect(!r.html.isEmpty)
    #expect(r.blocks.count > 40)
    #expect(r.outline.first?.text == "Hostile document")
    // the hostile heading never becomes more than text in the outline
    #expect(r.outline.contains { $0.text.contains("<img") })
}

// Export and Copy HTML: output that leaves the app carries no active content from the document (CopyHTML.render and the CLI
// ask for `RenderOptions.forExport`). The control is the same document rendered for the preview, which keeps it.

private func liveMarkup(in html: String) -> [String] {
    var found: [String] = []
    for tag in ["<script", "<iframe", "<frame", "<object", "<embed", "<applet", "<meta", "<base", "<link", "<noscript", "<animate", "<set "] where html.range(of: tag, options: .caseInsensitive) != nil {
        found.append(tag)
    }
    for tag in html.matches(of: /<[a-zA-Z][^>]*>/) {  // real tags only: the escaped text of an attack in a paragraph is just text
        let unquoted = String(tag.output).replacing(/"[^"]*"/, with: "\"\"")
        if unquoted.range(of: #"\son[a-z]+\s*="#, options: [.regularExpression, .caseInsensitive]) != nil { found.append("handler in \(tag.output)") }
        if String(tag.output).range(of: #"(?:href|src|data|action)="\s*(?:javascript|vbscript|data:text|file|blob):"#, options: [.regularExpression, .caseInsensitive]) != nil { found.append("script or file URL in \(tag.output)") }
    }
    return found
}

@Test func theHostileDocumentReachesThePreviewButNotAnExport() async throws {
    let renderer = try JSCRenderer()
    let preview = try await renderer.render(hostile(), options: RenderOptions()).html
    #expect(!liveMarkup(in: preview).isEmpty, "the control no longer carries the payloads")

    let exported = try await renderer.render(hostile(), options: RenderOptions().forExport).html
    #expect(liveMarkup(in: exported) == [])
    let page = HTMLExporter.document(body: exported, title: "t", inlineImages: { _ in nil })
    #expect(liveMarkup(in: String(page[page.range(of: "<article")!.lowerBound...])) == [])
    #expect(page.contains(#"<meta http-equiv="Content-Security-Policy" content="script-src 'none'"#))  // belt and braces for whatever else gets in
    #expect(exported.contains("<a href=\"https://example.com/\" target=\"_blank\" rel=\"opener\">new window</a>"))  // ordinary raw HTML stays
}

@Test func exportOptionsAreSanitizedAndNothingElseChanges() {
    var options = RenderOptions()
    options.hardBreaks = true
    #expect(options.sanitize == false)
    let exported = options.forExport
    #expect(exported.sanitize && exported.hardBreaks)
    #expect(RenderOptions().sanitize == false)  // the preview's options are untouched
}

@Test func rawHTMLOffAndSanitizeAgree() async throws {
    var options = RenderOptions.init()
    options.allowRawHTML = false
    let escaped = try await JSCRenderer().render(hostile(), options: options.forExport).html
    #expect(liveMarkup(in: escaped) == [])
}

@Test func sanitizedRenderFailsClosedWhenTheSanitizerChunkIsMissing() async throws {
    let bare = try JSCRenderer(resolveChunk: { _ in nil })
    let hostileText = "<img src=x onerror=alert(1)>\n"
    await #expect(throws: RenderError.missingAsset("sanitize.chunk.js")) {
        _ = try await bare.render(hostileText, options: RenderOptions().forExport)
    }
    // The preview's options never need the chunk, and the same renderer still serves them.
    let preview = try await bare.render(hostileText, options: RenderOptions())
    #expect(preview.html.contains("onerror"))

    // A chunk that loads but never registers a sanitizer: the bundle itself refuses.
    let empty = FileManager.default.temporaryDirectory.appending(path: "empty-sanitizer-\(UUID().uuidString).js")
    try Data("/* registers nothing */".utf8).write(to: empty)
    defer { try? FileManager.default.removeItem(at: empty) }
    let silent = try JSCRenderer(resolveChunk: { $0 == "sanitize.chunk.js" ? empty : WebAssets.url($0) })
    await #expect(throws: RenderError.self) { _ = try await silent.render(hostileText, options: RenderOptions().forExport) }

    // The real chunk, found the usual way: sanitized.
    let real = try await JSCRenderer().render(hostileText, options: RenderOptions().forExport)
    #expect(!real.html.contains("onerror"))
}
