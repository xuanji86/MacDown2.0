import Foundation
import Testing
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
