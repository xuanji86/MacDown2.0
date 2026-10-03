import AppKit
import Testing
@testable import EditorKit

@MainActor
struct ScrollLineTests {
    @Test func lineIndexAndOffsetAreInverse() {
        let view = ViewTests.makeSizedView("a\nbb\n\nccc\ndddd")
        #expect(view.offsetOfLine(0) == 0)
        #expect(view.offsetOfLine(1) == 2)
        #expect(view.offsetOfLine(3) == 6)
        #expect(view.offsetOfLine(99) == 10)  // fewer lines than asked for: the last one
        for line in 0..<5 { #expect(view.lineIndex(atOffset: view.offsetOfLine(line)) == line) }
    }

    @Test func caretLineFollowsTheSelection() {
        let view = ViewTests.makeSizedView("a\nbb\n\nccc")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.caretLine == 0)
        view.setSelectedRange(NSRange(location: 3, length: 0))  // inside "bb"
        #expect(view.caretLine == 1)
        view.setSelectedRange(NSRange(location: 6, length: 0))  // start of "ccc"
        #expect(view.caretLine == 3)
    }

    @Test func scrollingToALineAndReadingItBack() {
        let text = (0..<2000).map { "line \($0) of the document" }.joined(separator: "\n")
        let view = ViewTests.makeSizedView(text)
        // TextKit 2 estimates the height of text it has not laid out, so a far jump lands within a few lines, not exactly.
        view.scroll(toLine: 1200)
        #expect(abs(view.topVisibleLine - 1200) < 60)
        view.scroll(toLine: 300.5)
        #expect(abs(view.topVisibleLine - 300.5) < 60)
        view.scroll(toLine: 0)
        #expect(view.topVisibleLine < 1.0)
    }
}
