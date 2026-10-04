import AppKit
import Testing
@testable import EditorKit

struct InlineCommandTests {
    @Test func wrapsASelectionAndKeepsItSelected() {
        #expect(run(.bold, "a ⟦word⟧ b") == "a **⟦word⟧** b")
        #expect(run(.italic, "⟦x⟧") == "*⟦x⟧*")
        #expect(run(.underline, "⟦x⟧") == "<u>⟦x⟧</u>")
        #expect(run(.strikethrough, "⟦x⟧") == "~~⟦x⟧~~")
        #expect(run(.highlight, "⟦x⟧") == "==⟦x⟧==")
        #expect(run(.inlineCode, "⟦x⟧") == "`⟦x⟧`")
    }

    @Test func commentWrapsAndUnwraps() {
        #expect(run(.comment, "a ⟦note⟧ b") == "a <!-- ⟦note⟧ --> b")
        #expect(run(.comment, "a |b") == "a <!-- | -->b")
        #expect(run(.comment, "a <!-- ⟦note⟧ --> b") == "a ⟦note⟧ b")
        #expect(run(.comment, "a ⟦<!-- note -->⟧ b") == "a ⟦note⟧ b")
        #expect(run(.comment, "a <!-- | -->b") == "a |b")
        #expect(run(.comment, "⟦你好\n😀⟧") == "<!-- ⟦你好\n😀⟧ -->")
    }

    @Test func aCaretGetsAnEmptyPairWithTheCaretBetween() {
        #expect(run(.bold, "a |b") == "a **|**b")
        #expect(run(.underline, "|") == "<u>|</u>")
    }

    @Test func applyingTwiceTogglesBack() {
        for command in [MarkdownCommand.bold, .italic, .underline, .strikethrough, .highlight, .inlineCode] {
            let once = run(command, "a ⟦word⟧ b")!
            #expect(run(command, once) == "a ⟦word⟧ b")
            let empty = run(command, "a |b")!
            #expect(run(command, empty) == "a |b")
        }
    }

    @Test func unwrapsWhenTheSelectionIncludesTheMarkers() {
        #expect(run(.bold, "a ⟦**word**⟧ b") == "a ⟦word⟧ b")
    }

    @Test func whitespaceAtTheSelectionEdgesStaysOutsideTheMarkers() {
        #expect(run(.bold, "a⟦ word ⟧b") == "a **⟦word⟧** b")
    }

    @Test func italicInsideBoldWrapsInsteadOfStrippingOneStar() {
        #expect(run(.italic, "**⟦x⟧**") == "***⟦x⟧***")
        #expect(run(.bold, "**⟦x⟧**") == "⟦x⟧")
    }

    @Test func surrogatePairsAndCJKAreWrappedWhole() {
        #expect(run(.bold, "😀⟦👍🏽⟧😀") == "😀**⟦👍🏽⟧**😀")
        #expect(run(.italic, "你好⟦世界⟧") == "你好*⟦世界⟧*")
        #expect(run(.bold, "😀|") == "😀**|**")
        #expect(run(.bold, run(.bold, "😀⟦👍🏽⟧")!) == "😀⟦👍🏽⟧")
    }

    @Test func codeBlockWrapsWholeLinesAndKeepsFencesOnTheirOwnLines() {
        #expect(run(.codeBlock, "⟦let x = 1⟧") == "```\n⟦let x = 1⟧\n```")
        #expect(run(.codeBlock, "a\n⟦b\nc\n⟧d") == "a\n```\n⟦b\nc⟧\n```\nd")
        #expect(run(.codeBlock, "|") == "```\n|\n```")
        #expect(run(.codeBlock, "ab|cd") == "ab\n```\n|\n```\ncd")
        #expect(run(.codeBlock, "⟦你好😀⟧") == "```\n⟦你好😀⟧\n```")
    }

    @Test func linkAndImageWrapTheSelection() {
        #expect(run(.link, "⟦text⟧") == "[text](|)")
        #expect(run(.link, "|") == "[|]()")
        #expect(run(.image, "⟦alt⟧") == "![alt](|)")
        #expect(run(.image, "|") == "![|]()")
        #expect(run(.link, "see ⟦你好😀⟧!") == "see [你好😀](|)!")
    }

    @Test func aClipboardURLIsFilledIn() {
        let url = "https://example.com/a?b=1"
        #expect(run(.link, "⟦text⟧", clipboard: "  \(url)\n") == "[text](\(url))|")
        #expect(run(.link, "|", clipboard: url) == "[|](\(url))")
        #expect(run(.image, "⟦alt⟧", clipboard: url) == "![alt](\(url))|")
    }

    @Test func aSelectedURLBecomesTheTargetWhenThereIsNoClipboardURL() {
        #expect(run(.link, "⟦https://example.com⟧") == "[|](https://example.com)")
        #expect(run(.link, "⟦text⟧", clipboard: "not a url") == "[text](|)")
    }

    @Test func urlDetectionIsStrict() {
        #expect(MarkdownCommand.url(in: "https://example.com") == "https://example.com")
        #expect(MarkdownCommand.url(in: "mailto:a@b.co") == "mailto:a@b.co")
        #expect(MarkdownCommand.url(in: "two words") == nil)
        #expect(MarkdownCommand.url(in: "https://") == nil)
        #expect(MarkdownCommand.url(in: "javascript:alert(1)") == nil)
        #expect(MarkdownCommand.url(in: "line\nbreak") == nil)
        #expect(MarkdownCommand.url(in: nil) == nil)
    }
}

struct LineCommandTests {
    @Test func headingsReplaceTheirLevel() {
        #expect(run(.heading(1), "ti|tle") == "# ti|tle")
        #expect(run(.heading(3), "## ti|tle") == "### ti|tle")
        #expect(run(.heading(6), "|") == "###### |")
        #expect(run(.heading(9), "x|") == "###### x|")  // clamped
        #expect(run(.heading(2), "## x|") == nil)
        #expect(run(.paragraph, "### ti|tle") == "ti|tle")
        #expect(run(.paragraph, "plain|") == nil)
        #expect(run(.paragraph, "#hashtag|") == nil)
        #expect(run(.paragraph, "####### seven|") == nil)
    }

    @Test func headingsApplyToEveryNonBlankLineOfASelection() {
        #expect(run(.heading(2), "⟦a\n\nb⟧") == "⟦## a\n\n## b⟧")
        #expect(run(.heading(1), "⟦你好\n😀⟧") == "⟦# 你好\n# 😀⟧")
    }

    @Test func selectingAWholeLineDoesNotReachTheNextOne() {
        #expect(run(.heading(1), "⟦a\n⟧b") == "⟦# a\n⟧b")
    }

    @Test func unorderedListToggles() {
        #expect(run(.unorderedList, "it|em") == "- it|em")
        #expect(run(.unorderedList, "- it|em") == "it|em")
        #expect(run(.unorderedList, "⟦a\n\nb⟧") == "⟦- a\n\n- b⟧")
        #expect(run(.unorderedList, "⟦- a\n- b⟧") == "⟦a\nb⟧")
        #expect(run(.unorderedList, "⟦- a\nb⟧") == "⟦- a\n- b⟧")  // mixed: apply to all
        #expect(run(.unorderedList, "* x|") == "x|")
        #expect(run(.unorderedList, "1. x|") == "- x|")  // ordered becomes unordered
        #expect(run(.unorderedList, "  nested|") == "  - nested|")
        #expect(run(.unorderedList, "😀 x|") == "- 😀 x|")
    }

    @Test func unorderedMarkerFollowsTheSetting() {
        var behavior = EditorBehavior()
        behavior.unorderedListMarker = "*"
        #expect(run(.unorderedList, "x|", behavior: behavior) == "* x|")
    }

    @Test func taskBoxesSurviveListConversion() {
        #expect(run(.orderedList, "- [ ] todo|") == "1. [ ] todo|")
    }

    @Test func orderedListNumbersAndToggles() {
        #expect(run(.orderedList, "⟦a\nb\nc⟧") == "⟦1. a\n2. b\n3. c⟧")
        #expect(run(.orderedList, "⟦1. a\n2. b⟧") == "⟦a\nb⟧")
        #expect(run(.orderedList, "- a|") == "1. a|")
        #expect(run(.orderedList, "⟦a\n\nb⟧") == "⟦1. a\n\n2. b⟧")
        #expect(run(.orderedList, "你|好") == "1. 你|好")
    }

    @Test func blockquoteToggles() {
        #expect(run(.blockquote, "q|") == "> q|")
        #expect(run(.blockquote, "> q|") == "q|")
        #expect(run(.blockquote, ">q|") == "q|")
        #expect(run(.blockquote, "> > q|") == "> q|")
        #expect(run(.blockquote, "⟦a\n\nb⟧") == "⟦> a\n>\n> b⟧")  // one block
        #expect(run(.blockquote, "⟦> a\n>\n> b⟧") == "⟦a\n\nb⟧")
        #expect(run(.blockquote, "|") == "> |")
        #expect(run(.blockquote, "- item|") == "> - item|")
    }

    @Test func indentAndOutdent() {
        #expect(run(.indent, "a|") == "    a|")
        #expect(run(.indent, "⟦a\n\nb⟧") == "⟦    a\n\n    b⟧")
        #expect(run(.outdent, "    a|") == "a|")
        #expect(run(.outdent, "      a|") == "  a|")
        #expect(run(.outdent, "  a|") == "a|")
        #expect(run(.outdent, "\ta|") == "a|")
        #expect(run(.outdent, "a|") == nil)
        #expect(run(.outdent, "⟦    你\n    😀⟧") == "⟦你\n😀⟧")
        var tabs = EditorBehavior()
        tabs.tabInsertsSpaces = false
        #expect(run(.indent, "a|", behavior: tabs) == "\ta|")
    }

    @Test func caretStaysWhereItWasInTheText() {
        #expect(run(.indent, "ab|c") == "    ab|c")
        #expect(run(.heading(2), "你好|世界") == "## 你好|世界")
        #expect(run(.heading(2), "|你好") == "## |你好")
        #expect(run(.unorderedList, "第一行|\n第二行") == "- 第一行|\n第二行")
    }

    @Test func textAfterTheRegionIsUntouched() {
        #expect(run(.unorderedList, "a\n⟦b⟧\nc") == "a\n⟦- b⟧\nc")
        #expect(run(.orderedList, "x\n⟦a\nb⟧\ny😀") == "x\n⟦1. a\n2. b⟧\ny😀")
    }
}

struct PageBreakCommandTests {
    private let m = MarkdownCommand.pageBreakMarker

    @Test func theMarkerIsPlainHTMLAndEvenInsideAParagraphItGoesBelowIt() {
        #expect(m == #"<div style="page-break-after: always"></div>"#)
        #expect(run(.pageBreak, "one|\n\nnext") == "one\n\n\(m)\n|\nnext")
        #expect(run(.pageBreak, "on|e\n\nnext") == "one\n\n\(m)\n|\nnext")  // below the line, not in the middle of it
    }

    @Test func aTouchingNextLineGetsItsBlankLine() {
        #expect(run(.pageBreak, "one|\nnext") == "one\n\n\(m)\n\n|next")
    }

    @Test func aBlankLineIsReplacedInsteadOfLeavingAGap() {
        #expect(run(.pageBreak, "one\n\n|\n\nnext") == "one\n\n\(m)\n|\nnext")
        #expect(run(.pageBreak, "one\n\n  |\n\nnext") == "one\n\n\(m)\n|\nnext")
    }

    @Test func endOfFileGetsItsNewline() {
        #expect(run(.pageBreak, "one|") == "one\n\n\(m)\n|")
        #expect(run(.pageBreak, "one|\n") == "one\n\n\(m)\n|")
        #expect(run(.pageBreak, "|") == "\(m)\n|")
    }

    @Test func aSelectionOfWholeLinesPutsItAfterTheLastOne() {
        #expect(run(.pageBreak, "⟦one\ntwo\n⟧three") == "one\ntwo\n\n\(m)\n\n|three")
        #expect(run(.pageBreak, "⟦one\ntwo⟧\nthree") == "one\ntwo\n\n\(m)\n\n|three")
    }
}
