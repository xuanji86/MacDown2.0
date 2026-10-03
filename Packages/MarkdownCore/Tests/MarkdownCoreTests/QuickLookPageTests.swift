import Foundation
import Testing
@testable import MarkdownCore

private func page(_ markdown: String, utType: String = "net.daringfireball.markdown", manifest: FlavorManifest? = nil, isEnabled: (String) -> Bool = { _ in true }) async throws -> QuickLookPage {
    try await QuickLookPage.make(data: Data(markdown.utf8), utType: utType, renderer: JSCRenderer(), manifest: manifest, isEnabled: isEnabled)
}

@Test func pageIsStaticStyledHTMLWithoutLineMarkers() async throws {
    let p = try await page("# Title\n\n- [x] done\n\n```swift\nlet x = 1\n```\n")
    #expect(p.html.hasPrefix("<!doctype html>"))
    #expect(p.html.contains(#"<article id="doc" data-flavor="markdown">"#))
    #expect(p.html.contains("<h1 id=\"title\">Title</h1>"))
    #expect(!p.html.contains("data-line"))
    #expect(!p.html.contains("<script"))
    #expect(p.html.contains("#doc"))  // preview-styles/github.css
    #expect(p.html.contains(".hljs-keyword"))  // hljs theme
    #expect(p.html.contains("hljs-keyword\">let"))  // highlighted
    #expect(p.attachments.isEmpty)
    #expect(!p.truncated)
}

@Test func mermaidStaysACodeBlock() async throws {
    let html = try await page("```mermaid\ngraph TD\n  A --> B\n```\n").html
    #expect(html.contains(#"data-lang="mermaid""#))
    #expect(html.contains("A --&gt; B"))
}

@Test func rawHTMLIsEscaped() async throws {
    let html = try await page("<script>alert(1)</script> <b>x</b>\n").html
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script&gt;"))
}

@Test func mathBringsKaTeXStylesAndFontAttachments() async throws {
    let p = try await page("Inline \\(a^2\\) here.\n")
    #expect(p.html.contains(#"class="katex""#))
    #expect(p.html.contains("url(cid:KaTeX_Main-Regular)"))
    #expect(!p.html.contains("url(fonts/"))
    #expect(p.attachments.count == 20)
    #expect(p.attachments.allSatisfy { $0.fileExtension == "woff2" && !$0.data.isEmpty })
    #expect(p.attachments.contains { $0.id == "KaTeX_Main-Regular" })
}

@Test func relativeImagesBecomePlaceholdersOthersStay() async throws {
    let p = try await page("![the pic](pic.png) ![](a/b.png) ![r](https://example.com/x.png) ![d](data:image/png;base64,AAAA) ![p](//cdn.example.com/x.png)")
    #expect(p.html.contains(#"<span class="md2-ql-note">[image: the pic]</span>"#))
    #expect(p.html.contains(#"<span class="md2-ql-note">[image: a/b.png]</span>"#))
    #expect(p.html.contains(#"<img src="https://example.com/x.png""#))
    #expect(p.html.contains(#"<img src="data:image/png;base64,AAAA""#))
    #expect(p.html.contains(#"<img src="//cdn.example.com/x.png""#))
    #expect(!p.html.contains(#"src="pic.png""#))
}

@Test func oversizedDocumentIsCutAtALineAndFlagged() async throws {
    let line = "中文行 line of text that is not short\n"
    let doc = String(repeating: line, count: QuickLookPage.maxBytes / line.utf8.count + 100)
    let data = Data(doc.utf8.prefix(QuickLookPage.maxBytes + 1))  // what the extension reads
    let (text, truncated) = QuickLookPage.decode(data)
    #expect(truncated)
    #expect(text.hasSuffix("not short"))  // cut at a line boundary, so no half character and no U+FFFD
    #expect(!text.contains("\u{FFFD}"))
    let p = try await QuickLookPage.make(data: data, utType: "net.daringfireball.markdown", renderer: JSCRenderer(), manifest: nil)
    #expect(p.truncated)
    #expect(p.html.contains("md2-ql-truncated"))
    #expect(p.html.contains("MacDown2.0"))
    // exactly at the limit is not truncated
    #expect(!QuickLookPage.decode(Data(repeating: 0x61, count: QuickLookPage.maxBytes)).truncated)
}

@Test func decodeHandlesBOMsAndUTF16() {
    #expect(QuickLookPage.decode(Data([0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x41])).text == "# A")
    #expect(QuickLookPage.decode("# 中".data(using: .utf16)!).text == "# 中")  // utf16 data carries a BOM
}

@Test func flavorFollowsTheSettingAndUnclaimedTypesStayMarkdown() async throws {
    let url = try #require(Bundle.module.url(forResource: "flavors.json", withExtension: nil, subdirectory: "Fixtures"))
    let manifest = try FlavorManifest(data: Data(contentsOf: url))
    let off = try await page("# x", utType: "org.quarto.qmd", manifest: manifest, isEnabled: { _ in false })
    #expect(off.html.contains(#"data-flavor="markdown""#))
    let other = try await page("# x", utType: "net.daringfireball.markdown", manifest: manifest)
    #expect(other.html.contains(#"data-flavor="markdown""#))
    // enabled: the manifest's chunk is requested (the fixture manifest names a chunk that is not bundled yet)
    await #expect(throws: RenderError.missingAsset("quarto.chunk.js")) {
        _ = try await page("# x", utType: "org.quarto.qmd", manifest: manifest)
    }
}

/// S5: a 100 KB document through the whole Quick Look path. The real budget (< 500 ms, JavaScriptCore interpreter inside the
/// sandboxed extension) is measured with `qlmanage` (see PLAN appendix A item 4); here a loose bound catches order-of-magnitude regressions.
@Test func hundredKilobyteDocumentRendersQuickly() async throws {
    let section = "## Section\n\nText with **bold**, `code`, \\(x^2\\) and 中文.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n"
    let doc = String(repeating: section, count: 100 * 1024 / section.utf8.count)
    let renderer = try JSCRenderer()
    let start = ContinuousClock.now
    let p = try await QuickLookPage.make(data: Data(doc.utf8), utType: "net.daringfireball.markdown", renderer: renderer, manifest: nil)
    let elapsed = ContinuousClock.now - start
    print("QuickLookPage 100 KB: \(elapsed)")
    #expect(!p.truncated)
    #expect(elapsed < .seconds(3))
}
