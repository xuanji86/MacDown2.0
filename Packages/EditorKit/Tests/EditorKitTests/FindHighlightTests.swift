import AppKit
import Testing
@testable import EditorKit

@MainActor
struct FindHighlightTests {
    @MainActor
    private final class MockUndoProvider: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private func makeView(_ text: String) -> (MarkdownTextView, MockUndoProvider) {
        let view = ViewTests.makeSizedView(text)
        let undo = MockUndoProvider()
        view.delegate = undo
        return (view, undo)
    }

    @Test func highlightsAreDisplayedAndCleared() {
        let (view, _) = makeView("one two three two one")
        let ranges = [
            NSRange(location: 4, length: 3),
            NSRange(location: 14, length: 3),
        ]
        view.showFindHighlights(ranges, activeIndex: 0)
        #expect(view.findHighlightRanges == ranges)

        view.clearFindHighlights()
        #expect(view.findHighlightRanges.isEmpty)
    }

    @Test func replaceMatchIsUndoable() {
        let (view, undo) = makeView("hello world hello")
        let target = NSRange(location: 0, length: 5)
        let newRange = view.replaceMatch(range: target, with: "hi", actionName: "Replace")

        #expect(newRange == NSRange(location: 0, length: 2))
        #expect(view.string == "hi world hello")
        #expect(view.selectedRange() == NSRange(location: 0, length: 2))

        undo.manager.undo()
        #expect(view.string == "hello world hello")
    }

    @Test func replaceMatchesReplacesInReverseOrderWithSingleUndo() {
        let (view, undo) = makeView("cat and cat and cat")
        let replacements = [
            (range: NSRange(location: 0, length: 3), string: "dog"),
            (range: NSRange(location: 8, length: 3), string: "elephant"),
            (range: NSRange(location: 16, length: 3), string: "bird"),
        ]

        let count = view.replaceMatches(replacements, actionName: "Replace All")
        #expect(count == 3)
        #expect(view.string == "dog and elephant and bird")

        // Single undo step reverts all 3 replacements
        undo.manager.undo()
        #expect(view.string == "cat and cat and cat")
    }
}
