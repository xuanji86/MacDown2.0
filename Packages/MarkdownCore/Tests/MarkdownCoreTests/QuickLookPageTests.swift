import Foundation
import Testing
@testable import MarkdownCore

private func page(_ markdown: String, utType: String = "net.daringfireball.markdown", manifest: FlavorManifest? = nil, directory: URL? = nil, isEnabled: ((String) -> Bool)? = nil) async throws -> QuickLookPage {
    try await QuickLookPage.make(data: Data(markdown.utf8), utType: utType, renderer: JSCRenderer(), manifest: manifest, documentDirectory: directory, isEnabled: isEnabled)
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
    #expect(html.contains(#"class="mermaid-source""#))
    #expect(html.contains("A --&gt; B"))
    #expect(!html.contains("<script"))  // nothing here to draw it: the chunk is only ever loaded by the preview and print pages
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

@Test func localImagesBecomeCidAttachments() async throws {
    let t = try ResolverTree(); defer { t.remove() }
    let p = try await page("![a](img/a%20b.png) ![again](img/a%20b.png) ![s](same.png)", directory: t.doc)
    #expect(p.html.contains(#"<img src="cid:md2-img-0" alt="a">"#))
    #expect(p.html.contains(#"<img src="cid:md2-img-0" alt="again">"#))  // same path, one attachment
    #expect(p.html.contains(#"<img src="cid:md2-img-1" alt="s">"#))  // the symlink is another path, read again
    #expect(p.attachments.map(\.id) == ["md2-img-0", "md2-img-1"])
    #expect(p.attachments.allSatisfy { $0.fileExtension == "png" && $0.data == Data("png".utf8) })
    #expect(!p.html.contains("md2-ql-note\">[image"))
}

@Test func localImagesOutsideTheFolderOrNotImagesStayPlaceholders() async throws {
    let t = try ResolverTree(); defer { t.remove() }
    try Data("text".utf8).write(to: t.doc.appending(path: "notes.txt"))
    let p = try await page("![up](../secret.txt) ![up2](img/../../secret.txt) ![link](out.txt) ![dir](outdir/secret.txt) ![txt](notes.txt) ![gone](missing.png) ![abs](/etc/hosts)", directory: t.doc)
    #expect(p.attachments.isEmpty)
    #expect(!p.html.contains("<img"))
    #expect(p.html.components(separatedBy: #"class="md2-ql-note">[image"#).count == 8)
}

@Test func localImageCapsAreEnforced() async throws {
    let t = try ResolverTree(); defer { t.remove() }
    let nine = Data(count: 9 * 1024 * 1024)
    try Data(count: QuickLookPage.maxImageBytes + 1).write(to: t.doc.appending(path: "big.png"))
    try Data(count: QuickLookPage.maxImageBytes).write(to: t.doc.appending(path: "exact.png"))
    for i in 0..<6 { try nine.write(to: t.doc.appending(path: "n\(i).png")) }
    let over = try await page("![big](big.png) ![ok](exact.png)", directory: t.doc)
    #expect(over.attachments.count == 1)
    #expect(over.html.contains("[image: big]"))
    // 10 MB (exact) + 4 x 9 MB = 46 MB fits; the 5th 9 MB image would make 55 MB and stays a placeholder.
    let total = try await page("![](exact.png) ![](n0.png) ![](n1.png) ![](n2.png) ![](n3.png) ![](n4.png) ![](n5.png)", directory: t.doc)
    #expect(total.attachments.count == 5)
    #expect(total.attachments.reduce(0) { $0 + $1.data.count } <= QuickLookPage.maxTotalImageBytes)
    #expect(total.html.contains("[image: n4.png]") && total.html.contains("[image: n5.png]"))
}

@Test func appPreferencesDriveTheQuickLookPage() async throws {
    let suite = "ql-prefs-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = Data("line one\nline two\n\n<b>raw</b>\n".utf8)
    func make(_ d: UserDefaults?) async throws -> QuickLookPage {
        try await QuickLookPage.make(data: source, utType: "net.daringfireball.markdown", renderer: JSCRenderer(), manifest: nil, defaults: d)
    }
    let plain = try await make(nil)
    #expect(!plain.html.contains("<br"))
    #expect(plain.html.contains(#"content="light""#))

    defaults.set(true, forKey: RenderPreferences.Key.hardBreaks)
    defaults.set(true, forKey: RenderPreferences.Key.allowRawHTML)  // the app allows raw HTML; Quick Look still must not
    defaults.set("github-dark", forKey: "previewStyle")
    let custom = try await make(defaults)
    #expect(custom.html.contains("<br"))
    #expect(custom.html.contains("&lt;b&gt;raw"))
    #expect(custom.html.contains(#"content="light dark""#))
    #expect(custom.html != plain.html)
}

@Test func extensionSwitchesComeFromTheAppPreferences() async throws {
    let suite = "ql-prefs-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = try #require(Bundle.module.url(forResource: "flavors.json", withExtension: nil, subdirectory: "Fixtures"))
    let manifest = try FlavorManifest(data: Data(contentsOf: url))
    func render() async throws -> QuickLookPage {
        try await QuickLookPage.make(data: Data("# x\n".utf8), utType: "org.quarto.qmd", renderer: JSCRenderer(), manifest: manifest, defaults: defaults)
    }
    // unset = on: the manifest's chunk is loaded (it is bundled now)
    #expect(try await render().html.contains(#"data-flavor="quarto""#))
    defaults.set(false, forKey: "extension.quarto.enabled")
    #expect(try await render().html.contains(#"data-flavor="markdown""#))
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
    // enabled: the manifest's chunk is loaded (it is bundled now) and its stylesheet joins the page
    let on = try await page("::: {.callout-note}\nhi\n:::\n", utType: "org.quarto.qmd", manifest: manifest)
    #expect(on.html.contains(#"data-flavor="quarto""#))
    #expect(on.html.contains(#"class="callout callout-note"#))
    #expect(on.html.contains("quarto-approx") == false && on.html.contains(".callout-icon"))  // the CSS, inlined
    // a manifest that names a chunk that is not there fails loudly instead of rendering something else
    let broken = try FlavorManifest(data: Data(#"{"x": {"utTypes": ["x.y"], "chunks": ["nope.chunk.js"], "stylesheets": [], "settingKey": "k"}}"#.utf8))
    await #expect(throws: RenderError.missingAsset("nope.chunk.js")) {
        _ = try await page("# x", utType: "x.y", manifest: broken)
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
