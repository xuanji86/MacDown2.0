import Foundation
import Testing
import WebAssets
@testable import MarkdownCore

private func render(_ markdown: String) async throws -> String {
    try await JSCRenderer().render(markdown, options: RenderOptions().forExport).html
}

@Test func exportCarriesNoSourceLineAttributesButKeepsTextThatLooksLikeThem() async throws {
    let source = "# T\n\npara `x data-line=\"3\" data-line-end=\"4\"` and data-line=\"5\" in prose\n\n```\n<p data-line=\"7\">\n```\n"
    let preview = try await JSCRenderer().render(source, options: RenderOptions()).html
    #expect(preview.contains(#"<h1 data-line="0" data-line-end="1""#))  // the preview does tag blocks
    let html = try await render(source)
    #expect(!html.contains("<h1 data-line"))
    #expect(!html.contains("<p data-line"))
    #expect(html.contains(#"x data-line="3" data-line-end="4""#))  // the sanitizer writes a literal `"` in text: it is content, not an attribute
    #expect(html.contains(#"and data-line="5" in prose"#))
    #expect(html.contains("&lt;p data-line=\"7\"&gt;"))
    let page = HTMLExporter.document(body: html, title: "t")
    #expect(page.contains(#"x data-line="3" data-line-end="4""#))
}

@Test func documentIsStandaloneWithStyleAndEscapedTitle() async throws {
    let html = HTMLExporter.document(body: try await render("# Hi\n\n```swift\nlet x = 1\n```\n"), title: "A & <B>")
    #expect(html.hasPrefix("<!doctype html>"))
    #expect(html.contains("<title>A &amp; &lt;B&gt;</title>"))
    #expect(html.contains("--fg:"))  // preview style (default is a light, fixed one: no media wrapper)
    #expect(html.contains(".hljs"))  // highlight theme
    #expect(!html.contains("@media screen"))
    #expect(!html.contains("data-line"))
    #expect(!html.contains("KaTeX_"))  // no math, no KaTeX CSS
    #expect(!html.contains("<link") && !html.contains("<script"))
}

@Test func darkStylePrintsWithItsLightPartner() throws {
    let dark = HTMLExporter.document(body: "<p>x</p>", title: "t", style: PreviewStyles.resolve(id: "github-dark", followSystem: false))
    let screen = try #require(dark.range(of: "@media screen{"))
    let print = try #require(dark.range(of: "@media print{"))
    #expect(dark[screen.upperBound..<print.lowerBound].contains("--bg: #0d1117"))
    #expect(dark[print.upperBound...].contains("--bg: #ffffff"))

    let pair = HTMLExporter.document(body: "<p>x</p>", title: "t", style: PreviewStyles.resolve(id: "github", followSystem: true))
    #expect(pair.contains("@media (prefers-color-scheme: light){"))
    #expect(pair.contains("@media (prefers-color-scheme: dark){"))
    #expect(pair.contains("@media print{"))
}

@Test func mathBringsKaTeXCSSWithFontsInlined() async throws {
    let html = HTMLExporter.document(body: try await render("Euler:\n\n$$\ne^{i\\pi}+1=0\n$$\n"), title: "m")
    #expect(html.contains("@font-face"))
    #expect(html.contains("url(data:font/woff2;base64,"))
    #expect(!html.contains("url(fonts/"))
}

@Test func relativeImagesInlineOnlyWhenAskedAndReadable() {
    let body = #"<p><img src="img/a%20b.png" alt="x"> <img src="https://e.com/y.png"> <img src="/abs.png"> <img src="data:image/png;base64,AA=="> <img src='gone.png'> <img src="c.svg?v=1#f"></p>"#
    #expect(HTMLExporter.document(body: body, title: "t").contains(#"src="img/a%20b.png""#))  // default: untouched

    let seen = Locked<[String]>([])
    let inlined = HTMLExporter.document(body: body, title: "t", inlineImages: { path in
        seen.withValue { $0.append(path) }
        switch path {
        case "img/a b.png": return (Data("PNG".utf8), "image/png")
        case "c.svg": return (Data("<svg/>".utf8), "image/svg+xml")
        default: return nil
        }
    })
    #expect(seen.value == ["img/a b.png", "gone.png", "c.svg"])  // absolute, root-relative and data: never asked for
    #expect(inlined.contains(#"src="data:image/png;base64,\#(Data("PNG".utf8).base64EncodedString())""#))
    #expect(inlined.contains(#"src="data:image/svg+xml;base64,"#))
    #expect(inlined.contains(#"src="https://e.com/y.png""#) && inlined.contains(#"src="/abs.png""#))
    #expect(inlined.contains("src='gone.png'"))  // unreadable: left as written
}

@Test func flavorStylesheetsAndIdGoIntoTheStandaloneFile() {
    let plain = HTMLExporter.document(body: "<p>x</p>", title: "t")
    #expect(plain.contains(#"<article id="doc" data-flavor="markdown">"#))
    let quarto = HTMLExporter.document(body: "<p>x</p>", title: "t", flavor: "quarto", stylesheets: ["quarto-approx.css"])
    #expect(quarto.contains(#"<article id="doc" data-flavor="quarto">"#))
    #expect(quarto.contains(".callout"))  // quarto-approx.css, inlined
    #expect(!plain.contains(".callout"))
}

@Test func printStylesheetComesAfterTheStyleAndBeforeTheUsersOwn() throws {
    let html = HTMLExporter.document(body: "<p>x</p>", title: "t", flavor: "quarto", stylesheets: ["quarto-approx.css"], userCSS: "p { color: red }")
    let style = try #require(html.range(of: "--fg:"))
    let flavor = try #require(html.range(of: ".callout"))
    let print = try #require(html.range(of: "break-after: page"))  // print.css: the page-break rule
    let user = try #require(html.range(of: "p { color: red }"))
    #expect(style.lowerBound < flavor.lowerBound && flavor.lowerBound < print.lowerBound && print.lowerBound < user.lowerBound)
    #expect(!HTMLExporter.document(body: "<p>x</p>", title: "t").contains("p { color: red }"))
}

@Test func printStylesheetKeepsCodeInsideThePageAndTheCJKSearchable() throws {
    let css = try #require(WebAssets.url("print.css").flatMap { try? String(contentsOf: $0, encoding: .utf8) })
    #expect(css.contains("white-space: pre-wrap"))  // code blocks wrap instead of being cut off
    #expect(css.contains("break-inside: avoid"))
    #expect(css.contains("break-after: avoid"))  // a heading stays with what follows
    #expect(css.contains("background: none"))  // no grey desk
    #expect(css.contains("Hiragino Sans GB"))  // CJK whose text layer is not Kangxi radicals (see print.css)
    #expect(css.contains(".md2-page-break"))
}

@Test func theUsersStylesheetCannotEndItsStyleElementEarly() throws {
    let html = HTMLExporter.document(body: "<p>x</p>", title: "t", userCSS: "a{} </STYLE><script>alert(1)</script>")
    let payload = try #require(html.range(of: "alert(1)"))
    let end = try #require(html.range(of: "</style>", range: payload.upperBound..<html.endIndex))
    #expect(html[payload.upperBound..<end.lowerBound] == "</script>")  // the style element ends after the payload, not before it
    #expect(!html[..<payload.lowerBound].contains("</STYLE>"))
}

@Test func imageSourceStaysInsideTheDocumentFolder() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "HTMLExporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir.appending(path: "img"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("PNG".utf8).write(to: dir.appending(path: "img/a.png"))
    try Data("text".utf8).write(to: dir.appending(path: "notes.txt"))
    let secret = dir.deletingLastPathComponent().appending(path: "HTMLExporterTests-outside-\(UUID().uuidString).png")
    try Data("SECRET".utf8).write(to: secret)
    defer { try? FileManager.default.removeItem(at: secret) }

    let source = HTMLExporter.imageSource(directory: dir)
    #expect(source("img/a.png")?.mime == "image/png")
    #expect(source("notes.txt") == nil)  // not an image
    #expect(source("../\(secret.lastPathComponent)") == nil)  // outside the folder
    #expect(HTMLExporter.imageSource(directory: nil)("img/a.png") == nil)
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withValue(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
