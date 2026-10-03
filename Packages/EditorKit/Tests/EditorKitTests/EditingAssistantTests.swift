import AppKit
import Testing
@testable import EditorKit

struct AutoPairTests {
    @Test func bracketsAndQuotesPairAtABoundary() {
        #expect(press(.typed("("), "|") == "(|)")
        #expect(press(.typed("["), "a |") == "a [|]")
        #expect(press(.typed("{"), "|") == "{|}")
        #expect(press(.typed("\""), "say |") == "say \"|\"")
        #expect(press(.typed("'"), "|") == "'|'")
        #expect(press(.typed("`"), "|") == "`|`")
        #expect(press(.typed("_"), "a |") == "a _|_")
        #expect(press(.typed("*"), "a |") == "a *|*")
    }

    @Test func nothingPairsInsideAWordOrBeforeOne() {
        #expect(press(.typed("("), "|word") == nil)
        #expect(press(.typed("'"), "don|") == nil)  // apostrophe
        #expect(press(.typed("\""), "|word") == nil)
        #expect(press(.typed("_"), "snake|") == nil)
        #expect(press(.typed("*"), "a|b") == nil)
        #expect(press(.typed("`"), "x|y") == nil)
    }

    @Test func aBulletStarAtTheStartOfALineIsLeftAlone() {
        #expect(press(.typed("*"), "|") == nil)
        #expect(press(.typed("*"), "  |") == nil)
        #expect(press(.typed("*"), "text\n|") == nil)
    }

    @Test func typingTheClosingHalfStepsOver() {
        #expect(press(.typed(")"), "(a|)") == "(a)|")
        #expect(press(.typed("]"), "[a|]") == "[a]|")
        #expect(press(.typed("}"), "{|}") == "{}|")
        #expect(press(.typed("\""), "\"a|\"") == "\"a\"|")
        #expect(press(.typed("`"), "`a|`") == "`a`|")
        #expect(press(.typed(")"), "a|") == nil)
    }

    @Test func asterisksAndUnderscoresMakeBoldPairsThenStepOver() {
        #expect(press(.typed("*"), "a *|*") == "a **|**")  // second star: bold pair
        #expect(press(.typed("*"), "a **|**") == "a ***|*")  // then over the closers
        #expect(press(.typed("_"), "_|_") == "__|__")
        #expect(press(.typed("*"), "a *word|*") == "a *word*|")
        #expect(press(.typed("*"), "a **word|**") == "a **word*|*")
    }

    @Test func aSelectionIsWrappedAndStaysSelected() {
        #expect(press(.typed("("), "⟦x⟧") == "(⟦x⟧)")
        #expect(press(.typed("\""), "a ⟦word⟧") == "a \"⟦word⟧\"")
        #expect(press(.typed("*"), "⟦x⟧") == "*⟦x⟧*")
        #expect(press(.typed("_"), "⟦x⟧") == "_⟦x⟧_")
        #expect(press(.typed("`"), "⟦x⟧") == "`⟦x⟧`")
        #expect(press(.typed("["), "⟦你好😀⟧") == "[⟦你好😀⟧]")
        #expect(press(.typed(")"), "⟦x⟧") == nil)  // a closer replaces the selection as usual
    }

    @Test func cjkIsABoundaryButLettersAreNot() {
        #expect(press(.typed("("), "|你好") == "(|)你好")
        #expect(press(.typed("\""), "你好|") == "你好\"|\"")
        #expect(press(.typed("\""), "😀|") == "😀\"|\"")
        #expect(press(.typed("\""), "é|") == nil)
        #expect(press(.typed("("), "|é") == nil)
    }

    @Test func backspaceRemovesAnEmptyPairTogether() {
        #expect(press(.backspace, "(|)") == "|")
        #expect(press(.backspace, "a \"|\" b") == "a | b")
        #expect(press(.backspace, "**|**") == "*|*")
        #expect(press(.backspace, "(a|)") == nil)
        #expect(press(.backspace, "(|") == nil)
        #expect(press(.backspace, "⟦(⟧)") == nil)
        #expect(press(.backspace, "你(|)好") == "你|好")
    }

    @Test func otherCharactersAndSettingsAreIgnored() {
        #expect(press(.typed("a"), "|") == nil)
        #expect(press(.typed("你"), "|") == nil)
        #expect(press(.typed("(("), "|") == nil)
        var off = EditorBehavior()
        off.autoPair = false
        #expect(press(.typed("("), "|", behavior: off) == nil)
        #expect(press(.backspace, "(|)", behavior: off) == nil)
    }
}

struct ReturnKeyTests {
    @Test func continuesBulletsInTheSameStyle() {
        #expect(press(.newline, "- item|") == "- item\n- |")
        #expect(press(.newline, "* item|") == "* item\n* |")
        #expect(press(.newline, "+ item|") == "+ item\n+ |")
        #expect(press(.newline, "  - nested|") == "  - nested\n  - |")
        #expect(press(.newline, "- 你好😀|") == "- 你好😀\n- |")
    }

    @Test func numbersOrderedListsAutomatically() {
        #expect(press(.newline, "1. one|") == "1. one\n2. |")
        #expect(press(.newline, "9) nine|") == "9) nine\n10) |")
        #expect(press(.newline, "3. three|\n4. four") == "3. three\n4. |\n4. four")
        var off = EditorBehavior()
        off.autoNumberLists = false
        #expect(press(.newline, "3. three|", behavior: off) == "3. three\n3. |")
    }

    @Test func continuesTaskListsWithAnUncheckedBox() {
        #expect(press(.newline, "- [ ] todo|") == "- [ ] todo\n- [ ] |")
        #expect(press(.newline, "- [x] done|") == "- [x] done\n- [ ] |")
        #expect(press(.newline, "1. [ ] a|") == "1. [ ] a\n2. [ ] |")
    }

    @Test func continuesQuotes() {
        #expect(press(.newline, "> quote|") == "> quote\n> |")
        #expect(press(.newline, "> > deep|") == "> > deep\n> > |")
        #expect(press(.newline, "> - item|") == "> - item\n> - |")
    }

    @Test func anEmptyItemEndsTheList() {
        #expect(press(.newline, "- item\n- |") == "- item\n|")
        #expect(press(.newline, "1. a\n2. |") == "1. a\n|")
        #expect(press(.newline, "- [ ] |") == "|")
        #expect(press(.newline, "  - |") == "|")
        #expect(press(.newline, "> |") == "|")
        #expect(press(.newline, "> - |") == "> |")  // leaves the list, stays in the quote
    }

    @Test func splitsTheItemAtTheCaret() {
        #expect(press(.newline, "- ab|cd") == "- ab\n- |cd")
        #expect(press(.newline, "- 你|好") == "- 你\n- |好")
    }

    @Test func aCaretInsideTheMarkerGetsAPlainNewline() {
        #expect(press(.newline, "|- item") == nil)
        #expect(press(.newline, "-| item") == nil)
    }

    @Test func aSelectionIsReplacedByTheNewline() {
        #expect(press(.newline, "- a⟦bc⟧d") == "- a\n- |d")
    }

    @Test func plainLinesAreLeftAloneExceptForIndentation() {
        #expect(press(.newline, "plain text|") == nil)
        #expect(press(.newline, "    code|") == "    code\n    |")
        #expect(press(.newline, "\tcode|") == "\tcode\n\t|")
        #expect(press(.newline, "    |") == nil)
        #expect(press(.newline, "**bold**|") == nil)
        #expect(press(.newline, "---|") == nil)
        #expect(press(.newline, "1.5 litres|") == nil)
    }

    @Test func canBeSwitchedOff() {
        var off = EditorBehavior()
        off.continueLists = false
        #expect(press(.newline, "- item|", behavior: off) == nil)
    }
}

struct TabKeyTests {
    @Test func tabIndentsAListItemFromAnywhereOnTheLine() {
        #expect(press(.tab, "- it|em") == "    - it|em")
        #expect(press(.tab, "|- item") == "    |- item")
        #expect(press(.tab, "1. a|") == "    1. a|")
        #expect(press(.tab, "- [ ] a|") == "    - [ ] a|")
    }

    @Test func shiftTabOutdents() {
        #expect(press(.backtab, "    - it|em") == "- it|em")
        #expect(press(.backtab, "  - a|") == "- a|")
        #expect(press(.backtab, "plain|") == nil)
        #expect(press(.backtab, "⟦    a\n    b⟧") == "⟦a\nb⟧")
    }

    @Test func tabInPlainTextInsertsSpacesUpToTheNextStop() {
        #expect(press(.tab, "|") == "    |")
        #expect(press(.tab, "ab|") == "ab  |")
        #expect(press(.tab, "abcd|") == "abcd    |")
        #expect(press(.tab, "你好|") == "你好  |")
    }

    @Test func tabsCanBeKept() {
        var tabs = EditorBehavior()
        tabs.tabInsertsSpaces = false
        #expect(press(.tab, "ab|", behavior: tabs) == nil)  // the text view inserts a real tab
        #expect(press(.tab, "- a|", behavior: tabs) == "\t- a|")
        #expect(press(.backtab, "\t- a|", behavior: tabs) == "- a|")
    }

    @Test func aMultiLineSelectionIsIndentedAsLines() {
        #expect(press(.tab, "⟦a\nb⟧") == "⟦    a\n    b⟧")
        #expect(press(.tab, "⟦- a\n- b⟧") == "⟦    - a\n    - b⟧")
    }

    @Test func aSelectionInsideOneLineIsReplacedByTheTab() {
        #expect(press(.tab, "a⟦bc⟧d") == "a   |d")
    }

    @Test func tabIsPlainWhenListHandlingIsOff() {
        var off = EditorBehavior()
        off.continueLists = false
        #expect(press(.tab, "- a|", behavior: off) == "- a |")
    }
}
