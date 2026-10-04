import Foundation
import Testing
@testable import CLIKit
import MarkdownCore

// End to end through `CLI.run`: the real bundle in JavaScriptCore, a fixture file in, HTML out.
// Goldens are this renderer's output, reviewed by hand. Regenerate with `SNAPSHOT_UPDATE=1 swift test`.

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
private let fixtureSources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

private func renderFixture(_ name: String, _ extra: [String] = [], defaults: UserDefaults? = Scratch.emptyDefaults()) async throws -> (code: Int32, out: String, err: String, scratch: Scratch) {
    let s = try Scratch()
    try FileManager.default.copyItem(at: fixtures.appending(path: name), to: s.root.appending(path: name))
    let code = await CLI.run(["render", name] + extra, host: s.host(defaults: defaults))
    return (code, s.recorder.out, s.recorder.err, s)
}

private func matchesGolden(_ text: String, _ name: String) throws -> Bool {
    if ProcessInfo.processInfo.environment["SNAPSHOT_UPDATE"] == "1" { try text.write(to: fixtureSources.appending(path: name), atomically: true, encoding: .utf8) }
    return try String(contentsOf: fixtures.appending(path: name), encoding: .utf8) == text
}

@Test func renderPrintsTheHTMLFragment() async throws {
    let r = try await renderFixture("basic.md"); defer { r.scratch.remove() }
    #expect(r.code == 0 && r.err == "")
    #expect(try matchesGolden(r.out, "basic.html"))
    #expect(!r.out.contains("data-line"))  // scroll-sync markers are for the preview, not for output
    #expect(!r.out.contains("<html"))
}

@Test func standaloneIsACompletePageAroundTheSameBody() async throws {
    let r = try await renderFixture("basic.md", ["--standalone"]); defer { r.scratch.remove() }
    #expect(r.code == 0)
    #expect(r.out.hasPrefix("<!doctype html>"))
    #expect(r.out.contains("<title>basic</title>") && r.out.contains("<style>"))
    #expect(r.out.contains(#"<article id="doc" data-flavor="markdown">"#))
    #expect(r.out.contains("<h1") && r.out.contains("Hello, CLI") && r.out.contains("<table>"))
    #expect(r.out.contains("katex"))  // math is rendered, so the KaTeX CSS travels with the page
}

@Test func outputGoesToTheFileWithO() async throws {
    let r = try await renderFixture("basic.md", ["-o", "out/../out.html"]); defer { r.scratch.remove() }
    #expect(r.code == 0 && r.out == "")  // nothing on stdout
    #expect(try String(contentsOf: r.scratch.root.appending(path: "out.html"), encoding: .utf8) == String(contentsOf: fixtures.appending(path: "basic.html"), encoding: .utf8))
}

@Test func qmdRendersAsQuartoByDefault() async throws {
    let r = try await renderFixture("quarto.qmd", ["--standalone"]); defer { r.scratch.remove() }
    #expect(r.code == 0)
    #expect(r.out.contains(#"data-flavor="quarto""#))
    #expect(r.out.contains("callout"))
    let fragment = try await renderFixture("quarto.qmd"); defer { fragment.scratch.remove() }
    #expect(try matchesGolden(fragment.out, "quarto.html"))
}

@Test func qmdIsPlainMarkdownWhenTheAppSwitchedQuartoOff() async throws {
    let defaults = Scratch.emptyDefaults()
    defaults.set(false, forKey: "extension.quarto.enabled")
    let r = try await renderFixture("quarto.qmd", ["--standalone"], defaults: defaults); defer { r.scratch.remove() }
    #expect(r.code == 0)
    #expect(r.out.contains(#"data-flavor="markdown""#))
}

@Test func theAppsRenderSettingsApply() async throws {
    let defaults = Scratch.emptyDefaults()
    defaults.set(false, forKey: RenderPreferences.Key.ext(.tables))
    let r = try await renderFixture("basic.md", defaults: defaults); defer { r.scratch.remove() }
    #expect(r.code == 0 && !r.out.contains("<table>"))
}

@Test func unreadablePreferencesMeanDefaults() async throws {
    let r = try await renderFixture("quarto.qmd", ["--standalone"], defaults: nil); defer { r.scratch.remove() }
    #expect(r.code == 0 && r.out.contains(#"data-flavor="quarto""#))  // Quarto on, as in a fresh install
}

@Test func renderFileErrorsExit66() async throws {
    let s = try Scratch(); defer { s.remove() }
    #expect(await CLI.run(["render", "missing.md"], host: s.host()) == 66)
    try s.write("dir/x.md")
    #expect(await CLI.run(["render", "dir"], host: s.host()) == 66)
    #expect(s.recorder.err.contains("is a folder"))
    try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: s.root.appending(path: "bad.md"))  // not UTF-8
    #expect(await CLI.run(["render", "bad.md"], host: s.host()) == 66)
    try s.write("ok.md")
    #expect(await CLI.run(["render", "ok.md", "-o", "no-such-dir/out.html"], host: s.host(defaults: Scratch.emptyDefaults())) == 66)
    #expect(s.recorder.out == "")
}

@Test func renderUsageErrorsExit64() async throws {
    let s = try Scratch(); defer { s.remove() }
    #expect(await CLI.run(["render"], host: s.host()) == 64)
    #expect(s.recorder.err.contains("render needs a file"))
}
