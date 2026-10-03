import Foundation
import Testing
import WebAssets
@testable import MarkdownCore

private func render(_ markdown: String) async throws -> String {
    try await JSCRenderer().render(markdown, options: RenderOptions()).html
}

@Test func stripsSourceLineAttributes() async throws {
    let html = try await render("# T\n\npara\n")
    #expect(html.contains("data-line"))  // the renderer does tag blocks
    #expect(!HTMLExporter.stripSourceLines(html).contains("data-line"))
    #expect(HTMLExporter.stripSourceLines(#"<p data-line="3" data-line-end="4" id="x">"#) == #"<p id="x">"#)
}

@Test func documentIsStandaloneWithStyleAndEscapedTitle() async throws {
    let html = HTMLExporter.document(body: try await render("# Hi\n\n```swift\nlet x = 1\n```\n"), title: "A & <B>")
    #expect(html.hasPrefix("<!doctype html>"))
    #expect(html.contains("<title>A &amp; &lt;B&gt;</title>"))
    #expect(html.contains("--fg:"))  // preview style (default is a light, fixed one: no media wrapper)
    #expect(html.contains(".hljs"))  // highlight theme
    #expect(!html.contains("@media screen"))
    #expect(!html.contains("data-line"))
    #expect(!html.contains("@font-face"))  // no math, no KaTeX CSS
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

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withValue(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
