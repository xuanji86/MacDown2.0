import Foundation
import Testing
@testable import CLIKit
import MarkdownCore
import WebAssets

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

// MARK: --export, --css, --embed-images

@Test func exportHTMLIsACompletePageWithThePrintRulesAndTheUsersCSS() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md", "# Hi\n\n\\newpage\n\ntext\n")
    try s.write("my.css", "/* mine */ body { color: tomato }\n")
    let code = await CLI.run(["render", "a.md", "--export", "html", "--css", "my.css", "-o", "out.html"], host: s.host(defaults: Scratch.emptyDefaults()))
    #expect(code == 0 && s.recorder.out == "" && s.recorder.err == "")
    let html = try String(contentsOf: s.root.appending(path: "out.html"), encoding: .utf8)
    #expect(html.hasPrefix("<!doctype html>") && html.contains("body { color: tomato }"))
    #expect(html.contains(#"<div class="md2-page-break""#) && html.contains("break-after: page"))  // marker rendered, print.css inlined
    #expect(try #require(html.range(of: "break-after: page")).lowerBound < #require(html.range(of: "color: tomato")).lowerBound)
}

@Test func cssAloneMakesAPageAndEmbedImagesInlinesTheFolderOnly() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md", "![x](pic.png) ![y](../outside.png)\n")
    try s.write("pic.png", "PNGDATA")
    try s.write("my.css", "p{}")
    let out = await CLI.run(["render", "a.md", "--css", "my.css", "--embed-images"], host: s.host(defaults: Scratch.emptyDefaults()))
    #expect(out == 0 && s.recorder.out.hasPrefix("<!doctype html>"))
    #expect(s.recorder.out.contains("data:image/png;base64,\(Data("PNGDATA".utf8).base64EncodedString())"))
    #expect(s.recorder.out.contains(#"src="../outside.png""#))  // outside the document folder: left alone
}

@Test func cssReadsOnlyTheNamedLocalFile() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md")
    try s.write("imports.css", "/* ok */ @IMPORT url(other.css);")
    try s.write("commented.css", "/* @import url(other.css); */ p { color: red }")
    try s.write("dir/x.css")
    try Data([0xFF, 0xFE, 0x00]).write(to: s.root.appending(path: "bad.css"))
    func run(_ css: String) async -> Int32 { await CLI.run(["render", "a.md", "--css", css], host: s.host(defaults: Scratch.emptyDefaults())) }
    #expect(await run("https://example.com/x.css") == 64)
    #expect(await run("file:///etc/hosts") == 64)
    #expect(await run("imports.css") == 64)
    #expect(await run("missing.css") == 66)
    #expect(await run("dir") == 66)
    #expect(await run("bad.css") == 66)
    #expect(await run("commented.css") == 0)  // a comment about @import is not one
}

@Test func cssImportsAndRemoteURLsAreRefusedHoweverTheyAreSpelled() {
    let refused = [
        "@import url(x.css);", "@IMPORT 'x.css';", "@ImPoRt \"x.css\";",
        #"@\69mport url(//evil.example/x.css);"#, #"@\000069mport url(x.css);"#, #"@\69 mport url(x.css);"#, #"@\49MPORT url(x.css);"#,
        #"@i\6d port 'x';"#, #"@\i\m\p\o\r\t 'x';"#,
        "/* c */ @import url(x.css);", "/* a */ /* b */\n@\\69mport url(x.css);", "p{}\n@import url(x.css);",
        "p { background: url(https://evil.example/a.png) }", "p { background: url( 'HTTP://evil.example/a.png' ) }",
        "p { background: url(\"//evil.example/a.png\") }", #"p { background: u\72l(http://evil.example/a.png) }"#,
        #"p { background: \75 rl(https://evil.example/a.png) }"#, "p { background: url(ftp://x/a) }", "p { background: url(file:///etc/passwd) }",
        "p { background: url(java\tscript:alert(1)) }", "@font-face { src: url(https://evil.example/f.woff2) }",
    ]
    for css in refused { #expect(Render.remoteReference(in: css) != nil, "not refused: \(css)") }
    let fine = [
        "", "p { color: red }", "/* @import url(x.css); */ p { color: red }", "/* multi\nline @import url(x.css);\n*/ p{}",
        "p { background: url(img/a.png) }", "p { background: url('/Users/me/a.png') }", "p { background: url(\"a b.png\") }",
        "p { background: url(data:image/png;base64,AAAA) }", "p { background: url( DATA:image/svg+xml,%3Csvg%3E ) }",
        "p::after { content: \"\\201C\" }", "a:hover{color:#123}",
    ]
    for css in fine { #expect(Render.remoteReference(in: css) == nil, "refused: \(css)") }
}

@Test func anEscapedImportInACSSFileFailsTheCommand() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md")
    try s.write("esc.css", #"@\69mport url(https://evil.example/x.css); p{}"#)
    try s.write("remote.css", "p { background: url(https://evil.example/a.png) }")
    for css in ["esc.css", "remote.css"] {
        #expect(await CLI.run(["render", "a.md", "--export", "html", "--css", css, "-o", "out.html"], host: s.host(defaults: Scratch.emptyDefaults())) == 64, "\(css)")
        #expect(!FileManager.default.fileExists(atPath: s.root.appending(path: "out.html").path))
    }
}

@Test func exportPDFHandsThePageAndTheAppsPaperSettingsToTheWriter() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md", "# 标题\n")
    let defaults = Scratch.emptyDefaults()
    defaults.set("a4", forKey: PageSetup.Key.paper)
    defaults.set("landscape", forKey: PageSetup.Key.orientation)
    defaults.set(20.0, forKey: PageSetup.Key.left)
    let seen = Locked<(html: String, setup: PageSetup)?>(nil)
    let host = s.host(defaults: defaults, renderPDF: { html, setup in seen.set((html, setup)); return Data("%PDF-stub".utf8) })
    #expect(await CLI.run(["render", "a.md", "--export", "pdf", "-o", "out.pdf"], host: host) == 0)
    #expect(try Data(contentsOf: s.root.appending(path: "out.pdf")) == Data("%PDF-stub".utf8))
    #expect(s.recorder.out == "")
    let got = try #require(seen.value)
    #expect(got.html.hasPrefix("<!doctype html>") && got.html.contains("标题"))
    #expect(got.setup.paper == .a4 && got.setup.orientation == .landscape && got.setup.left == 20)
}

@Test func pdfWriterFailuresAreReportedAndNothingIsWritten() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md")
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
    let failing = s.host(defaults: Scratch.emptyDefaults(), renderPDF: { _, _ in throw Boom() })
    #expect(await CLI.run(["render", "a.md", "--export", "pdf", "-o", "out.pdf"], host: failing) == 70)
    #expect(s.recorder.err.contains("could not write the PDF: boom"))
    #expect(!FileManager.default.fileExists(atPath: s.root.appending(path: "out.pdf").path))
    // A build without a PDF writer says so instead of crashing.
    #expect(await CLI.run(["render", "a.md", "--export", "pdf", "-o", "out.pdf"], host: s.host(defaults: Scratch.emptyDefaults())) == 69)
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ new: T) { lock.withLock { stored = new } }
}

@Test func quartoIncludesAreReadFromTheDocumentFolderOnly() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("main.qmd", "# Main\n\n{{< include child.qmd >}}\n\n> {{< include quoted.qmd >}}\n\n{{< include ../outside.qmd >}}\n\n{{< include missing.qmd >}}\n")
    try s.write("child.qmd", "CHILD TEXT\n\n{{< include sub/grand.qmd >}}\n")
    try s.write("sub/grand.qmd", "GRAND TEXT\n")
    try s.write("quoted.qmd", "QUOTED TEXT\n")
    try s.write("../outside.qmd", "OUTSIDE SECRET\n")
    defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent().appending(path: "outside.qmd")) }
    let code = await CLI.run(["render", "main.qmd"], host: s.host(defaults: Scratch.emptyDefaults()))
    #expect(code == 0)
    #expect(s.recorder.out.contains("CHILD TEXT") && s.recorder.out.contains("GRAND TEXT") && s.recorder.out.contains("QUOTED TEXT"))
    #expect(!s.recorder.out.contains("OUTSIDE SECRET"))
    #expect(s.recorder.out.contains("outside the document folder") && s.recorder.out.contains("not found"))  // refused and missing ones say so
}

@Test func renderOutputCarriesNoActiveContentFromAHostileDocument() async throws {
    let hostile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../MarkdownCore/Tests/MarkdownCoreTests/Fixtures/own/hostile.md").standardizedFileURL
    let s = try Scratch(); defer { s.remove() }
    try FileManager.default.copyItem(at: hostile, to: s.root.appending(path: "hostile.md"))
    for extra in [[], ["--standalone"]] as [[String]] {
        let before = s.recorder.out.count
        #expect(await CLI.run(["render", "hostile.md"] + extra, host: s.host(defaults: Scratch.emptyDefaults())) == 0)
        let out = String(s.recorder.out.dropFirst(before))
        let article = out.range(of: "<article").map { String(out[$0.lowerBound...]) } ?? out
        for tag in ["<script", "<iframe", "<object", "<embed", "<meta", "<base", "<link"] { #expect(!article.contains(tag), "\(tag) in \(extra)") }
        for tag in article.matches(of: /<[a-zA-Z][^>]*>/) {  // an event handler inside a real tag (quoted values blanked: a title may quote an attack as text)
            let unquoted = String(tag.output).replacing(/"[^"]*"/, with: "\"\"")
            #expect(unquoted.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil, "\(tag.output)")
        }
        #expect(article.range(of: #"href="\s*javascript:"#, options: [.regularExpression, .caseInsensitive]) == nil)
    }
}

@Test func theAppsBlockRemoteImagesSwitchReachesTheExportedPageAndEmbedsTheLocalImages() async throws {
    let s = try Scratch(); defer { s.remove() }
    try s.write("a.md", "![x](pic.png) ![y](https://example.com/remote.png)\n")
    try s.write("pic.png", "PNGDATA")
    let off = Scratch.emptyDefaults()
    #expect(await CLI.run(["render", "a.md", "--standalone"], host: s.host(defaults: off)) == 0)
    #expect(!s.recorder.out.contains(RemoteContent.printContentSecurityPolicy) && s.recorder.out.contains(#"src="pic.png""#))

    let on = Scratch.emptyDefaults()
    on.set(true, forKey: RemoteContent.blockImagesKey)
    let blocked = try Scratch(); defer { blocked.remove() }
    try blocked.write("a.md", "![x](pic.png) ![y](https://example.com/remote.png)\n")
    try blocked.write("pic.png", "PNGDATA")
    #expect(await CLI.run(["render", "a.md", "--standalone"], host: blocked.host(defaults: on)) == 0)
    #expect(blocked.recorder.out.contains(RemoteContent.printContentSecurityPolicy))  // no network origin in the page
    #expect(blocked.recorder.out.contains("data:image/png;base64,"))  // and no path either, so the local image is inside
    #expect(blocked.recorder.out.contains(#"src="https://example.com/remote.png""#))  // the remote one is left to the CSP to refuse
}
