import ExtensionAPI
import Foundation
import MarkdownCore
import Testing
@testable import QuartoExtension

// The official Quarto example documents (Web/test/fixtures/quarto, sources in its README) through the real chunk in
// JavaScriptCore: no error, and byte-for-byte the output the Node tests snapshot (Web/test/snapshots/quarto), so the
// WebView, JavaScriptCore (export, Quick Look) and Node all agree.

private let web = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Web/test")

private let examples: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: web.appending(path: "fixtures/quarto").path)) ?? [])
    .filter { $0.hasSuffix(".qmd") }.map { String($0.dropLast(4)) }.sorted()

/// Same switches as `quartoOptions({ codeLineNumbers: true, frontMatterDisplay: 'table' })` in Web/test/helpers/quarto.mjs.
private func options(for source: String) -> RenderOptions {
    var options = RenderOptions()
    options.extensions = Set(MarkdownExtension.allCases).subtracting([.smartPunctuation])
    options.codeLineNumbers = true
    options.frontMatterDisplay = .table
    return options.rendering(as: QuartoFlavor(), markdown: source) { _ in nil }
}

@Test func examplesArePresent() {
    #expect(examples.count >= 5)
}

@Test("Quarto official examples: approximate preview", arguments: examples)
func exampleRendersAndMatchesTheNodeSnapshot(name: String) async throws {
    let source = try String(contentsOf: web.appending(path: "fixtures/quarto/\(name).qmd"), encoding: .utf8)
    let result = try await JSCRenderer().render(source, options: options(for: source))
    let golden = try String(contentsOf: web.appending(path: "snapshots/quarto/\(name).html"), encoding: .utf8)
    #expect(result.html == golden, "\(name): JavaScriptCore output differs from the Node snapshot")
    #expect(!result.html.isEmpty)
}

@Test func includedFilesAreInlinedThroughTheOptionsAndOutsideOnesAreRefused() async throws {
    let files = ["a.qmd": "## From A\n\nbody", "sub/b.qmd": "B"]
    let source = "# Main\n\n{{< include a.qmd >}}\n\n{{< include ../outside.qmd >}}\n\n{{< include sub/b.qmd >}}\n"
    var options = RenderOptions().rendering(as: QuartoFlavor(), markdown: source) { files[$0] }
    #expect(options.files == files)
    let result = try await JSCRenderer().render(source, options: options)
    #expect(result.html.contains(#"data-include="a.qmd""#) && result.html.contains(#"data-include="sub/b.qmd""#))
    #expect(result.html.contains("../outside.qmd</code>: outside the document folder"))
    #expect(result.outline.map(\.text) == ["Main", "From A"])
    #expect(result.blocks.count == 4)  // heading + three includes, each one block mapped to its include line

    options.files = [:]  // Quick Look and anything else that does not read files
    #expect(try await JSCRenderer().render(source, options: options).html.contains("a.qmd</code>: not found"))
}
