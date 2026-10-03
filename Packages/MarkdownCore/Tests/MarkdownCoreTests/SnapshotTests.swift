import Foundation
import Testing
@testable import MarkdownCore

// Rendering snapshots (PLAN §6.1): the macdown3000 corpus plus our own syntax fixtures go through the
// real bundle in JavaScriptCore; the output is compared with the golden files in `Snapshots/`.
// Goldens are this renderer's own output, reviewed by hand. Regenerate with `SNAPSHOT_UPDATE=1 swift test`.

private let snapshotsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Snapshots")

private func fixturesDir(_ name: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: name)
}

private func markdownFiles(in name: String) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: fixturesDir(name).path)) ?? []
    return files.filter { $0.hasSuffix(".md") && $0 != "README.md" }.map { String($0.dropLast(3)) }.sorted()
}

private let macdown3000 = markdownFiles(in: "macdown3000")

/// Every extension on, line numbers on, front matter shown as a table.
private var everything: RenderOptions {
    var options = RenderOptions()
    options.extensions = Set(MarkdownExtension.allCases)
    options.codeLineNumbers = true
    options.frontMatterDisplay = .table
    return options
}

private func check(html: String, snapshot: String) throws {
    let url = snapshotsDir.appending(path: snapshot)
    if ProcessInfo.processInfo.environment["SNAPSHOT_UPDATE"] == "1" {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("missing snapshot \(snapshot); run SNAPSHOT_UPDATE=1 swift test")
        return
    }
    #expect(html == golden, "\(snapshot) differs from its golden file")
}

@Test func corpusIsPresent() {
    #expect(macdown3000.count == 31)
}

@Test("macdown3000 corpus, default options", arguments: macdown3000)
func macdown3000Snapshot(name: String) async throws {
    let source = try String(contentsOf: fixturesDir("macdown3000").appending(path: "\(name).md"), encoding: .utf8)
    let result = try await JSCRenderer().render(source, options: RenderOptions())
    try check(html: result.html, snapshot: "macdown3000/\(name).html")
}

@Test func syntaxShowcaseSnapshot() async throws {
    let source = try String(contentsOf: fixturesDir("own").appending(path: "syntax-showcase.md"), encoding: .utf8)
    let result = try await JSCRenderer().render(source, options: everything)
    try check(html: result.html, snapshot: "own/syntax-showcase.html")
}

@Test func cjkEmphasisSnapshot() async throws {
    let source = try String(contentsOf: fixturesDir("own").appending(path: "cjk-emphasis.md"), encoding: .utf8)
    let result = try await JSCRenderer().render(source, options: RenderOptions())
    try check(html: result.html, snapshot: "own/cjk-emphasis.html")
}
