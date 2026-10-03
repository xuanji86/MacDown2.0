import Foundation
import Testing
@testable import MarkdownCore

// The Swift enums and the JS renderer must agree on option names; these tests fail when they drift.

private func render(_ source: String, _ configure: (inout RenderOptions) -> Void = { _ in }) async throws -> RenderResult {
    var options = RenderOptions()
    configure(&options)
    return try await JSCRenderer().render(source, options: options)
}

@Test func defaultsFollowSettingsPage() {
    let options = RenderOptions()
    #expect(options.extensions == [.tables, .strikethrough, .autolink, .mark, .footnotes, .taskLists, .math, .toc, .frontMatter, .cjkEmphasis])
    #expect(options.codeHighlighting && !options.codeLineNumbers)
    #expect(options.mathDelimiters == .both && options.frontMatterDisplay == .hidden)
}

@Test func optionsEncodeWithTheNamesTheBundleReads() throws {
    var options = RenderOptions()
    options.extensions = [.cjkEmphasis, .taskLists, .frontMatter]
    options.mathDelimiters = .brackets
    options.frontMatterDisplay = .table
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
    #expect((json["extensions"] as? [String])?.sorted() == ["cjkEmphasis", "frontMatter", "taskLists"])
    #expect(json["mathDelimiters"] as? String == "brackets")
    #expect(json["frontMatterDisplay"] as? String == "table")
    #expect(json["codeHighlighting"] as? Bool == true && json["codeLineNumbers"] as? Bool == false)
}

private let probes: [(MarkdownExtension, source: String, marker: String)] = [
    (.tables, "| a |\n|---|\n| b |", "<table"),
    (.strikethrough, "~~x~~", "<s>"),
    (.autolink, "see https://example.com", "<a href=\"https://example.com\""),
    (.smartPunctuation, "\"x\"", "“"),
    (.mark, "==x==", "<mark>"),
    (.sup, "x^2^", "<sup>2</sup>"),
    (.sub, "H~2~O", "<sub>2</sub>"),
    (.underline, "_x_", "<u>x</u>"),
    (.footnotes, "a[^1]\n\n[^1]: n", "footnote-ref"),
    (.taskLists, "- [x] a", "task-list-item-checkbox"),
    (.math, "$x$", "class=\"katex\""),
    (.toc, "[TOC]\n\n# A", "<nav class=\"toc\""),
    (.frontMatter, "---\na: 1\n---\n", "class=\"front-matter\""),
    (.cjkEmphasis, "**「重点」**的", "<strong>"),
]

@Test func everyExtensionCaseIsUnderstoodByTheBundle() async throws {
    #expect(Set(probes.map(\.0)) == Set(MarkdownExtension.allCases))
    for (ext, source, marker) in probes {
        let on = try await render(source) { $0.extensions = [ext] }
        #expect(on.html.contains(marker), "\(ext): expected \(marker) in \(on.html)")
        let off = try await render(source) { $0.extensions = [] }
        #expect(!off.html.contains(marker), "\(ext): \(marker) must need the extension")
    }
}

@Test func cjkFriendlyEmphasisIsOnByDefault() async throws {
    #expect(try await render("**「重点」**的").html.contains("<strong>「重点」</strong>的"))
    #expect(try await render("**「重点」**的") { $0.extensions.remove(.cjkEmphasis) }.html.contains("**「重点」**的"))
}

@Test func mathIsParsedBeforeEmphasis() async throws {
    let html = try await render("$a*b$ and $c*d$").html
    #expect(!html.contains("<em>"))
    #expect(html.contains("class=\"katex\""))
}

@Test func mathDelimiterModes() async throws {
    let source = "$a$ \\(b\\)"
    func katexCount(_ delimiters: MathDelimiters) async throws -> Int {
        let html = try await render(source) { $0.mathDelimiters = delimiters }.html
        return html.components(separatedBy: "class=\"katex\"").count - 1
    }
    #expect(try await katexCount(.dollars) == 1)
    #expect(try await katexCount(.brackets) == 1)
    #expect(try await katexCount(.both) == 2)
}

@Test func frontMatterIsReportedAndDisplayed() async throws {
    let source = "---\ntitle: Hi\n---\n\n# Body\n"
    let hidden = try await render(source)
    #expect(hidden.frontMatter == "title: Hi")
    #expect(hidden.html.contains("class=\"front-matter\" hidden") && !hidden.html.contains("Hi"))
    #expect(hidden.blocks.map(\.lineStart) == [0, 4])
    let table = try await render(source) { $0.frontMatterDisplay = .table }
    #expect(table.html.contains("<th>title</th><td>Hi</td>"))
    let off = try await render(source) { $0.extensions.remove(.frontMatter) }
    #expect(off.frontMatter == nil)
}

@Test func codeOptionsReachTheRenderer() async throws {
    let source = "```swift\nlet x = 1\n```"
    let plain = try await render(source).html
    #expect(plain.contains("hljs-keyword") && plain.contains("data-lang=\"swift\"") && !plain.contains("class=\"line\""))
    let numbered = try await render(source) { $0.codeLineNumbers = true }.html
    #expect(numbered.contains("class=\"line-numbers\"") && numbered.contains("<span class=\"line\">"))
    let off = try await render(source) { $0.codeHighlighting = false }.html
    #expect(!off.contains("hljs") && off.contains("data-lang=\"swift\""))
}
