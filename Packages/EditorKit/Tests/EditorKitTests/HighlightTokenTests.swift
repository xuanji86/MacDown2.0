import Foundation
import Testing
@testable import EditorKit

@MainActor
struct HighlightTokenTests {
    static let sample = """
    ---
    title: x
    ---

    # Heading *em*

    Some **bold**, _it_, `code`, ~~gone~~ and [link](http://a.b "t") ![img](p.png) <b> \\* &amp;.

    > quoted

    - item
    - [x] done

    ```swift
    let a = 1
    ```

        indented

    | a | b |
    |---|---|
    | 1 | 2 |

    ***

    Setext
    ======

    $$
    x^2
    $$

    [ref]: http://c.d
    """

    @Test func blockAndInlineConstructsGetTheirKinds() async throws {
        let h = try await EngineHarness(Self.sample)
        // Block nodes include their trailing newline; compare with surrounding whitespace trimmed.
        let s = Set(h.slices(try await h.tokens()).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "⏎") })
        let expected = [
            "frontMatter:---⏎title: x⏎---",
            "headingMarker:#", "heading:Heading *em*", "emphasis:*em*",
            "strong:**bold**", "emphasis:_it_", "code:`code`", "strikethrough:~~gone~~",
            "link:link", "linkURL:http://a.b", "image:img", "linkURL:p.png", "linkLabel:\"t\"",
            "html:<b>", "escape:\\*", "escape:&amp;",
            "quote:> quoted", "quoteMarker:>",
            "listMarker:-", "taskMarker:[x]",
            "codeBlock:```swift⏎let a = 1⏎```", "codeFence:swift",
            "codeBlock:    indented",
            "tableHeader:| a | b |", "tableDelimiter:|---|---|",
            "hr:***",
            "heading:Setext", "headingMarker:======",
            "math:$$⏎x^2⏎$$",
            "linkLabel:[ref]", "linkURL:http://c.d",
        ]
        for e in expected { #expect(s.contains(e), "missing \(e)") }
    }

    @Test func outerTokensComeBeforeInnerOnes() async throws {
        let h = try await EngineHarness("A **bold _both_ done** z")
        let slices = h.slices(try await h.tokens())
        let strong = try #require(slices.firstIndex(of: "strong:**bold _both_ done**"))
        let inner = try #require(slices.firstIndex(of: "emphasis:_both_"))
        #expect(strong < inner)
    }

    @Test func tokensAreClippedToTheRequestedRange() async throws {
        let h = try await EngineHarness("A **bold text** z")
        let range = NSRange(location: 4, length: 4)  // "bold"
        let tokens = try await h.tokens(in: range)
        #expect(!tokens.isEmpty)
        for t in tokens { #expect(NSIntersectionRange(t.range, range) == t.range) }
        #expect(h.slices(tokens).contains("strong:bold"))
    }

    @Test func rangesAreUTF16ForCJKAndSurrogatePairs() async throws {
        let h = try await EngineHarness("# 标题 😀\n\n中文 **粗体😀** 与 `代码`")
        let slices = h.slices(try await h.tokens())
        #expect(slices.contains("heading:标题 😀"))
        #expect(slices.contains("strong:**粗体😀**"))
        #expect(slices.contains("code:`代码`"))
    }

    @Test func inlineInsideBlockquoteAndListItems() async throws {
        let h = try await EngineHarness("> a *q*\n\n- b **l**\n  c `m`")
        let slices = h.slices(try await h.tokens())
        #expect(slices.contains("emphasis:*q*"))
        #expect(slices.contains("strong:**l**"))
        #expect(slices.contains("code:`m`"))
    }

    @Test func emptyAndWhitespaceDocumentsProduceNoTokens() async throws {
        let h = try await EngineHarness("")
        #expect(try await h.tokens().isEmpty)
        let w = try await EngineHarness("  \n\n")
        #expect(try await w.tokens().isEmpty)
    }
}
