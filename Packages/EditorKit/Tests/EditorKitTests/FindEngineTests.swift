import Foundation
import Testing
@testable import EditorKit

struct FindEngineTests {
    @Test func plainFindCaseInsensitive() {
        let text = "Hello world, HELLO universe, hello again"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "hello", isRegex: false, isCaseSensitive: false)
        #expect(!invalid)
        #expect(matches.count == 3)
        #expect(matches[0] == NSRange(location: 0, length: 5))
        #expect(matches[1] == NSRange(location: 13, length: 5))
        #expect(matches[2] == NSRange(location: 29, length: 5))
    }

    @Test func plainFindCaseSensitive() {
        let text = "Hello world, HELLO universe, hello again"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "hello", isRegex: false, isCaseSensitive: true)
        #expect(!invalid)
        #expect(matches.count == 1)
        #expect(matches[0] == NSRange(location: 29, length: 5))

        let (upperMatches, _) = FindEngine.findMatches(in: text, query: "HELLO", isRegex: false, isCaseSensitive: true)
        #expect(upperMatches.count == 1)
        #expect(upperMatches[0] == NSRange(location: 13, length: 5))
    }

    @Test func plainFindSpecialCharacters() {
        let text = "function(a, b) { return a.b; }"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "a.b", isRegex: false, isCaseSensitive: false)
        #expect(!invalid)
        #expect(matches.count == 1)
        #expect((text as NSString).substring(with: matches[0]) == "a.b")
    }

    @Test func regexFindCaseInsensitive() {
        let text = "Chapter 1: Intro\nchapter 2: Details\nCHAPTER 3: Summary"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "^chapter \\d+", isRegex: true, isCaseSensitive: false)
        #expect(!invalid)
        #expect(matches.count == 3)
        #expect((text as NSString).substring(with: matches[0]) == "Chapter 1")
        #expect((text as NSString).substring(with: matches[1]) == "chapter 2")
        #expect((text as NSString).substring(with: matches[2]) == "CHAPTER 3")
    }

    @Test func regexFindCaseSensitive() {
        let text = "Chapter 1: Intro\nchapter 2: Details\nCHAPTER 3: Summary"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "^chapter \\d+", isRegex: true, isCaseSensitive: true)
        #expect(!invalid)
        #expect(matches.count == 1)
        #expect((text as NSString).substring(with: matches[0]) == "chapter 2")
    }

    @Test func regexFindInvalidSyntax() {
        let text = "Some test text"
        let (matches, invalid) = FindEngine.findMatches(in: text, query: "[unclosed", isRegex: true, isCaseSensitive: false)
        #expect(invalid)
        #expect(matches.isEmpty)
    }

    @Test func plainReplacementIsLiteral() {
        let text = "item-100 and item-200"
        let range = NSRange(location: 0, length: 8)
        let result = FindEngine.replacementString(
            for: range,
            in: text,
            query: "item-100",
            replaceText: "$1_literal",
            isRegex: false,
            isCaseSensitive: false
        )
        #expect(result == "$1_literal")
    }

    @Test func regexReplacementExpandsCaptureGroups() {
        let text = "item-100 and item-200"
        let range1 = NSRange(location: 0, length: 8)
        let result1 = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "elem_$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(result1 == "elem_100")

        let range2 = NSRange(location: 13, length: 8)
        let result2 = FindEngine.replacementString(
            for: range2,
            in: text,
            query: "item-(\\d+)",
            replaceText: "elem_$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(result2 == "elem_200")

        let resultWithRealNewline = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "$1\n$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(resultWithRealNewline == "100\n100")

        let resultWithEscapedNewline = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "$1\\n$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(resultWithEscapedNewline == "100\n100")

        let resultWithEscapedTab = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "$1\\t$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(resultWithEscapedTab == "100\t100")

        let resultWithEscapedBackslash = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "$1\\\\$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(resultWithEscapedBackslash == "100\\100")

        let resultWithEscapedDollar = FindEngine.replacementString(
            for: range1,
            in: text,
            query: "item-(\\d+)",
            replaceText: "\\$$1",
            isRegex: true,
            isCaseSensitive: false
        )
        #expect(resultWithEscapedDollar == "$100")
    }

    @Test func nextAndPreviousNavigation() {
        let matches = [
            NSRange(location: 10, length: 5),
            NSRange(location: 30, length: 5),
            NSRange(location: 60, length: 5),
        ]

        // If selection is currently at match 0, next goes to match 1
        #expect(FindEngine.nextIndex(in: matches, currentLocation: 10, currentIndex: 0) == 1)
        // If selection is at match 2, next wraps around to match 0
        #expect(FindEngine.nextIndex(in: matches, currentLocation: 60, currentIndex: 2) == 0)

        // If caret is between match 0 and match 1 (e.g. at 20)
        #expect(FindEngine.nextIndex(in: matches, currentLocation: 20, currentIndex: -1) == 1)
        // If caret is past match 2 (e.g. at 80), wrap around to 0
        #expect(FindEngine.nextIndex(in: matches, currentLocation: 80, currentIndex: -1) == 0)

        // Previous from match 0 wraps to match 2
        #expect(FindEngine.previousIndex(in: matches, currentLocation: 10, currentIndex: 0) == 2)
        // Previous from match 1 goes to match 0
        #expect(FindEngine.previousIndex(in: matches, currentLocation: 30, currentIndex: 1) == 0)

        // If caret is at 45 (between match 1 and 2), previous goes to match 1
        #expect(FindEngine.previousIndex(in: matches, currentLocation: 45, currentIndex: -1) == 1)
        // If caret is at 5 (before match 0), previous wraps to match 2
        #expect(FindEngine.previousIndex(in: matches, currentLocation: 5, currentIndex: -1) == 2)
    }
}
