import AppKit
import Testing
@testable import EditorKit

@MainActor
struct LineNumberTests {
    /// A short line, a wrapped Latin paragraph, a short line, a wrapped CJK paragraph, a last line.
    static let wrapped = "short\n" + String(repeating: "word ", count: 400) + "\nthird\n" + String(repeating: "中文段落", count: 200) + "\nlast"

    @Test func wrappedLinesGetOneNumberOnTheirFirstRow() {
        let view = ViewTests.makeSizedView(Self.wrapped)
        let marks = view.lineMarks(in: view.visibleRect.union(NSRect(x: 0, y: 0, width: 1, height: 100_000)))
        #expect(marks.map(\.number) == [1, 2, 3, 4, 5])
        let tops = marks.map(\.top)
        #expect(tops == tops.sorted())
        // Rows: the wrapped lines are several times as tall as a one-row line, and every number sits inside its own line.
        #expect(marks[1].height > marks[0].height * 3)
        #expect(marks[3].height > marks[0].height * 3)
        for mark in marks { #expect(mark.baseline > mark.top && mark.baseline < mark.top + mark.height) }
        // The number is on the first row, not at the middle or bottom of the wrapped paragraph.
        #expect(marks[1].baseline < marks[1].top + 2 * marks[0].height)
    }

    @Test func numbersStartAtTheFirstVisibleLine() {
        let text = (0..<3000).map { "line \($0)" }.joined(separator: "\n")
        let view = ViewTests.makeSizedView(text)
        view.scroll(toLine: 1500)
        let marks = view.lineMarks(in: view.visibleRect)
        let first = try! #require(marks.first)
        // Number = 1-based source line, and the numbers are consecutive.
        #expect(first.number == Int(view.topVisibleLine.rounded(.down)) + 1)
        #expect(marks.map(\.number) == Array(first.number..<first.number + marks.count))
        #expect(marks.count < 100)  // only the viewport, not the document
    }

    @Test func currentLineIsTheOneHoldingTheCaret() {
        let view = ViewTests.makeSizedView("a\nbb\n\nccc")
        func current() -> [Int] { view.lineMarks(in: view.visibleRect).filter(\.isCurrent).map(\.number) }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(current() == [1])
        view.setSelectedRange(NSRange(location: 3, length: 0))  // inside "bb"
        #expect(current() == [2])
        view.setSelectedRange(NSRange(location: 5, length: 0))  // the empty line
        #expect(current() == [3])
        view.setSelectedRange(NSRange(location: 9, length: 0))  // end of the text
        #expect(current() == [4])
    }

    @Test func trailingNewlineAddsAnEmptyLastLine() {
        let view = ViewTests.makeSizedView("a\nb\n")
        let marks = view.lineMarks(in: view.visibleRect)
        #expect(marks.map(\.number) == [1, 2, 3])
        #expect(view.lineCount == 3)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(marks.count == 3 && view.lineMarks(in: view.visibleRect).filter(\.isCurrent).map(\.number) == [3])
    }

    @Test func emptyDocumentHasLineOne() {
        let view = ViewTests.makeSizedView("")
        #expect(view.lineMarks(in: view.visibleRect).map(\.number) == [1])
    }

    @Test func rulerFollowsTheSettingAndKeepsTextKit2() throws {
        let view = ViewTests.makeSizedView("a\nb\n")
        let scrollView = try #require(view.enclosingScrollView)
        #expect(scrollView.rulersVisible == false)
        var settings = EditorViewSettings()
        settings.showsLineNumbers = true
        view.apply(settings: settings)
        #expect(scrollView.rulersVisible)
        #expect((view.gutter?.ruleThickness ?? 0) > 20)
        scrollView.layoutSubtreeIfNeeded()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.gutter?.display()
        #expect(view.textLayoutManager != nil, "a ruler must not downgrade the view to TextKit 1")
        settings.showsLineNumbers = false
        view.apply(settings: settings)
        #expect(scrollView.rulersVisible == false)
    }
}

@MainActor
struct SmartHomeTests {
    @Test func firstStopIsTheFirstNonBlankThenTheLineStart() {
        let text = "x\n    foo bar\ny" as NSString
        #expect(SmartHome.target(in: text, caret: 12) == 6)  // mid-line -> first non-blank
        #expect(SmartHome.target(in: text, caret: 6) == 2)  // on the first non-blank -> real start
        #expect(SmartHome.target(in: text, caret: 2) == 6)  // at the real start -> first non-blank again
        #expect(SmartHome.target(in: text, caret: 4) == 6)  // inside the indent
    }

    @Test func tabsCountAsBlankAndBlankLinesStayPut() {
        let text = "\t\tfoo\n   \n\n" as NSString
        #expect(SmartHome.target(in: text, caret: 5) == 2)
        #expect(SmartHome.target(in: text, caret: 2) == 0)
        #expect(SmartHome.target(in: text, caret: 6) == 9)  // whitespace-only line: the first non-blank is its end
        #expect(SmartHome.target(in: text, caret: 9) == 6)
        #expect(SmartHome.target(in: text, caret: 10) == 10)  // the empty last line
    }

    @Test func cjkIndentAndTextAreOrdinaryCharacters() {
        // The ideographic space U+3000 is not blank for this purpose (it is text in Markdown), so it is the first stop.
        let text = "  \u{3000}中文\n" as NSString
        #expect(SmartHome.target(in: text, caret: 5) == 2)
        #expect(SmartHome.target(in: text, caret: 2) == 0)
    }

    @Test func viewMovesInTwoSteps() {
        let view = ViewTests.makeSizedView("    foo bar\nnext")
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.moveToLeftEndOfLine(nil)
        #expect(view.selectedRange().location == 4)
        view.moveToLeftEndOfLine(nil)
        #expect(view.selectedRange().location == 0)
        view.moveToLeftEndOfLine(nil)
        #expect(view.selectedRange().location == 4)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.moveToBeginningOfLine(nil)
        #expect(view.selectedRange().location == 4)
    }

    @Test func offMeansTheSystemMove() {
        let view = ViewTests.makeSizedView("    foo bar\nnext")
        var settings = EditorViewSettings()
        settings.smartHome = false
        view.apply(settings: settings)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.moveToLeftEndOfLine(nil)
        #expect(view.selectedRange().location == 0)
    }

    @Test func aWrappedContinuationRowKeepsTheSystemBehaviour() {
        let view = ViewTests.makeSizedView("  " + String(repeating: "word ", count: 400))
        view.setSelectedRange(NSRange(location: 1500, length: 0))  // a later visual row
        view.moveToLeftEndOfLine(nil)
        let start = view.selectedRange().location
        #expect(start > 2 && start < 1500, "start of the visual row, neither the first non-blank nor the line start")
    }
}

@MainActor
struct ColumnWidthTests {
    @Test func insetCentresAColumnOfTheMaximumWidth() {
        #expect(EditorViewSettings.horizontalInset(viewWidth: 1000, maxWidth: 760) == 120)
        #expect(EditorViewSettings.horizontalInset(viewWidth: 1001, maxWidth: 760) == 121)  // rounded up: column <= 760
        #expect(EditorViewSettings.horizontalInset(viewWidth: 700, maxWidth: 760) == 15)  // narrower than the column: base inset
        #expect(EditorViewSettings.horizontalInset(viewWidth: 3000, maxWidth: nil) == 15)
    }

    @Test func viewTracksTheWidthAndTheSetting() throws {
        let view = ViewTests.makeSizedView("text")
        let scrollView = try #require(view.enclosingScrollView)
        // The original MacDown's insets: 15 across, 30 down.
        #expect(view.textContainerInset == NSSize(width: 15, height: 30))
        var settings = EditorViewSettings()
        settings.limitsWidth = true
        settings.maxWidth = 400
        view.apply(settings: settings)
        #expect(view.textContainerInset.width == ((view.bounds.width - 400) / 2).rounded(.up))
        #expect(view.textContainerInset.height == 30)
        let column = view.textContainer?.size.width ?? 0
        #expect(column <= 400 && column > 397)
        scrollView.setFrameSize(NSSize(width: 1000, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        #expect(view.textContainerInset.width == ((view.bounds.width - 400) / 2).rounded(.up))
        #expect(view.bounds.width > 700)
        settings.limitsWidth = false
        view.apply(settings: settings)
        #expect(view.textContainerInset == NSSize(width: 15, height: 30))
    }

    @Test func outOfRangeValuesAreClamped() {
        var settings = EditorViewSettings()
        settings.maxWidth = 5
        settings.lineSpacing = 99
        #expect(settings.clamped.maxWidth == 400)
        #expect(settings.clamped.lineSpacing == 12)
        settings.lineSpacing = -2
        #expect(settings.clamped.lineSpacing == 0)
    }
}

@MainActor
struct LineSpacingTests {
    @Test func defaultsAreTheOriginalMacDownsAndTheSettingChangesTheWholeText() throws {
        #expect(EditorViewSettings().lineSpacing == 3)
        let view = ViewTests.makeSizedView("one\ntwo\n")
        let storage = try #require(view.textStorage)
        func spacing(_ at: Int) -> CGFloat? { (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing }
        #expect(view.typingAttributes[.paragraphStyle] != nil)

        var settings = EditorViewSettings()
        settings.lineSpacing = 8
        view.apply(settings: settings)
        #expect(spacing(0) == 8)
        #expect(spacing(5) == 8)  // the whole text, not only what has been highlighted
        #expect((view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing == 8)
    }

    @Test func linesGetTallerWithTheSetting() {
        let view = ViewTests.makeSizedView((0..<20).map { "line \($0)" }.joined(separator: "\n"))
        let before = view.lineMarks(in: view.visibleRect)
        var settings = EditorViewSettings()
        settings.lineSpacing = 12
        view.apply(settings: settings)
        view.layoutSubtreeIfNeeded()
        let after = view.lineMarks(in: view.visibleRect)
        #expect(after[1].height > before[1].height + 6)  // [0]: TextKit adds the spacing above a line, so not above the first
    }
}

@MainActor
struct InvisiblesTests {
    @Test func theViewVendsFragmentsThatDrawMarksOnDemand() throws {
        let view = ViewTests.makeSizedView("a b\tc\n")
        let layout = try #require(view.textLayoutManager)
        var found: InvisiblesLayoutFragment?
        layout.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            found = fragment as? InvisiblesLayoutFragment
            return false
        }
        let fragment = try #require(found)
        #expect(fragment.marks?().enabled == false)
        var settings = EditorViewSettings()
        settings.showsInvisibles = true
        view.apply(settings: settings)
        #expect(fragment.marks?().enabled == true)
        #expect(fragment.renderingSurfaceBounds.width >= fragment.layoutFragmentFrame.width + 40)
        #expect(view.textLayoutManager != nil)
    }
}
