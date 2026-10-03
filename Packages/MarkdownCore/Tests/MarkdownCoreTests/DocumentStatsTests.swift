import Foundation
import Testing
@testable import MarkdownCore

/// The selection counter must agree with `textStats` in `Web/src/render/text.ts`. Plain one-paragraph texts render to
/// themselves, so the JS stats of the rendered page are the reference for the Swift count of the same text.
@Suite struct StatsParityTests {
    static let samples = [
        "hello world",
        "中文字数 hello",
        "It's a dog’s life, isn't it",
        "日本語のひらがなとカタカナ、々ー",
        "한국어 단어 세기",  // Hangul: space separated words, not CJK per character
        "café e\u{301}tude naïve",  // combining marks stay in the word and in one grapheme
        "family 👨‍👩‍👧‍👦 and flag 🇯🇵 done",
        "tabs\tand\u{a0}nbsp\u{3000}ideographic space",
        "numbers 3.14 and 1,000 and 2026",
        "snake_case and kebab-case",
        "Ünïcödé Ελληνικά Кириллица",
    ]

    @Test(arguments: samples) func matchesJavaScript(text: String) async throws {
        let reference = try await JSCRenderer().render(text, options: RenderOptions()).stats
        #expect(TextStats(counting: text) == reference, "\(text.debugDescription)")
    }
}

@Test func selectionCountingRules() {
    #expect(TextStats(counting: "") == TextStats(words: 0, characters: 0, charactersNoSpaces: 0))
    // Han counts per character, the Latin run is one word.
    #expect(TextStats(counting: "你好 world") == TextStats(words: 3, characters: 8, charactersNoSpaces: 7))
    // Line feeds are not characters; CRLF is one grapheme and whitespace.
    #expect(TextStats(counting: "a\nb") == TextStats(words: 2, characters: 2, charactersNoSpaces: 2))
    #expect(TextStats(counting: "a\r\nb") == TextStats(words: 2, characters: 3, charactersNoSpaces: 2))
}

@Test func countModeCyclesAndPicksTheNumber() {
    let stats = TextStats(words: 1, characters: 2, charactersNoSpaces: 3)
    #expect(CountMode.words.next == .characters)
    #expect(CountMode.characters.next == .charactersNoSpaces)
    #expect(CountMode.charactersNoSpaces.next == .words)
    #expect(CountMode.allCases.map(stats.count) == [1, 2, 3])
}

@Test func currentOutlineItemIsTheLastHeadingAtOrAboveTheLine() {
    let outline = [
        OutlineItem(level: 1, text: "A", slug: "a", line: 2),
        OutlineItem(level: 2, text: "B", slug: "b", line: 10),
        OutlineItem(level: 2, text: "C", slug: "c", line: 20),
    ]
    #expect(outline.currentIndex(forLine: 0) == nil)  // before the first heading
    #expect(outline.currentIndex(forLine: 2) == 0)
    #expect(outline.currentIndex(forLine: 9) == 0)
    #expect(outline.currentIndex(forLine: 10) == 1)
    #expect(outline.currentIndex(forLine: 999) == 2)
    #expect([OutlineItem]().currentIndex(forLine: 5) == nil)
}
