import Foundation
import Testing
@testable import MarkdownCore

private func fixture(_ name: String) -> URL? {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
}

@Test func rendersWithBundledAssets() async throws {
    let renderer = try JSCRenderer()
    let result = try await renderer.render("# 标题 Title\n\n中文字数 hello\n\n| a |\n|---|\n| b |\n", options: RenderOptions())
    #expect(result.html.contains(#"<h1 data-line="0" data-line-end="1" id="标题-title">"#))
    #expect(result.html.contains("<table"))
    #expect(result.blocks.map(\.lineStart) == [0, 2, 4])
    #expect(result.outline == [OutlineItem(level: 1, text: "标题 Title", slug: "标题-title", line: 0)])
    #expect(result.stats.words == 2 + 1 + 4 + 1 + 2)
}

@Test func optionsReachTheRenderer() async throws {
    let renderer = try JSCRenderer()
    var options = RenderOptions()
    options.extensions = []
    options.allowRawHTML = false
    let html = try await renderer.render("~~x~~ <b>y</b>", options: options).html
    #expect(!html.contains("<s>"))
    #expect(html.contains("&lt;b&gt;"))
}

@Test func flavorChunkLoadsOnceAndApplies() async throws {
    let renderer = try JSCRenderer(resolveChunk: { fixture($0) })
    var options = RenderOptions()
    options.flavor = "test"
    options.renderChunks = ["test.chunk.js"]
    _ = try await renderer.render("first", options: options)
    let html = try await renderer.render("second", options: options).html
    #expect(html.contains(#"class="test-flavor-1""#))
}

@Test func missingChunkAndUnknownFlavorThrow() async throws {
    let renderer = try JSCRenderer(resolveChunk: { _ in nil })
    var options = RenderOptions()
    options.flavor = "test"
    await #expect(throws: RenderError.script("Error: Unknown flavor \"test\"")) {
        try await renderer.render("x", options: options)
    }
    options.renderChunks = ["absent.chunk.js"]
    await #expect(throws: RenderError.missingAsset("absent.chunk.js")) {
        try await renderer.render("x", options: options)
    }
}

@Test func manifestResolvesOnlyEnabledFlavors() throws {
    let manifest = try FlavorManifest(data: Data(contentsOf: #require(fixture("flavors.json"))))
    let on = manifest.resolve(utType: "org.quarto.qmd") { $0 == "extension.quarto.enabled" }
    #expect(on.flavor == "quarto" && on.chunks == ["quarto.chunk.js"])
    #expect(manifest.resolve(utType: "org.quarto.qmd") { _ in false }.flavor == .markdown)
    #expect(manifest.resolve(utType: "net.daringfireball.markdown") { _ in true }.flavor == .markdown)
    _ = try FlavorManifest.bundled()
}

@Test func filesOptionReachesTheRendererAndPlainMarkdownIgnoresIt() async throws {
    var options = RenderOptions()
    options.files = ["a.qmd": "text"]
    let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
    #expect(json.contains(#""files":{"a.qmd":"text"}"#))
    let html = try await JSCRenderer().render("{{< include a.qmd >}}", options: options).html
    #expect(html.contains("quarto-include") == false)  // core Markdown: literal text, no include handling
    #expect(html.contains("include a.qmd"))
}
