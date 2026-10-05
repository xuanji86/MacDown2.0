import AppKit
import Testing
@testable import EditorKit

@MainActor
struct ScrollPastEndTests {
    static let text = (0..<200).map { "line \($0)" }.joined(separator: "\n")

    private func make() throws -> (MarkdownTextView, EditorClipView, NSScrollView) {
        let view = ViewTests.makeSizedView(Self.text)
        let scrollView = try #require(view.enclosingScrollView)
        let clip = try #require(scrollView.contentView as? EditorClipView)
        scrollView.layoutSubtreeIfNeeded()
        return (view, clip, scrollView)
    }

    /// The furthest the clip view lets the document scroll.
    private func maxOffset(_ clip: EditorClipView) -> CGFloat {
        clip.constrainBoundsRect(NSRect(x: 0, y: 1_000_000, width: clip.bounds.width, height: clip.bounds.height)).origin.y
    }

    @Test func offByDefaultTheLastLineStopsAtTheBottom() throws {
        let (view, clip, _) = try make()
        #expect(!view.viewSettings.scrollsPastEnd)
        #expect(abs(maxOffset(clip) - (view.frame.height - clip.bounds.height)) < 1)
    }

    @Test func onTheLastLineCanReachTheMiddleOfTheWindow() throws {
        let (view, clip, scrollView) = try make()
        let before = maxOffset(clip)
        var settings = EditorViewSettings()
        settings.scrollsPastEnd = true
        view.apply(settings: settings)
        let after = maxOffset(clip)
        #expect(abs((after - before) - (clip.bounds.height / 2).rounded(.down)) < 1)
        // And the text view itself is untouched: no fake height, still TextKit 2.
        #expect(view.textLayoutManager != nil)
        #expect(scrollView.documentView === view)

        view.scroll(toLine: 10_000)  // past the end: clamps to the new limit
        #expect(abs(clip.bounds.origin.y - after) < 1)
        // The last line is now about mid-window, not at the bottom.
        let lastLine = Double(view.lineCount - 1)
        #expect(view.topVisibleLine > lastLine - 25 && view.topVisibleLine < lastLine - 5, "top line is \(view.topVisibleLine)")
    }

    @Test func switchingOffBringsTheViewBack() throws {
        let (view, clip, _) = try make()
        var settings = EditorViewSettings()
        settings.scrollsPastEnd = true
        view.apply(settings: settings)
        view.scroll(toLine: 10_000)
        let far = clip.bounds.origin.y
        settings.scrollsPastEnd = false
        view.apply(settings: settings)
        #expect(clip.bounds.origin.y < far)
        #expect(abs(clip.bounds.origin.y - (view.frame.height - clip.bounds.height)) < 1)
    }

    @Test func scrollSyncStillMapsLinesBothWays() throws {
        let (view, _, _) = try make()
        var settings = EditorViewSettings()
        settings.scrollsPastEnd = true
        view.apply(settings: settings)
        for line in [0.0, 1.0, 57.0, 130.5, 180.0] {
            view.scroll(toLine: line)
            #expect(abs(view.topVisibleLine - line) < 0.05, "asked for \(line), got \(view.topVisibleLine)")
        }
    }

    @Test func aClickInTheExtraSpaceBelongsToTheText() throws {
        let (view, clip, _) = try make()
        let below = NSPoint(x: 10, y: view.frame.maxY + 50)
        #expect(!clip.isInExtraSpace(below), "off: nothing below the text")
        var settings = EditorViewSettings()
        settings.scrollsPastEnd = true
        view.apply(settings: settings)
        #expect(clip.isInExtraSpace(below))
        #expect(!clip.isInExtraSpace(NSPoint(x: 10, y: view.frame.maxY - 5)), "a click on the text itself is the text view's own")
    }

    @Test func aShortDocumentDoesNotScrollBeyondHalfAWindow() throws {
        let view = ViewTests.makeSizedView("a\nb\nc")
        let clip = try #require(view.enclosingScrollView?.contentView as? EditorClipView)
        var settings = EditorViewSettings()
        settings.scrollsPastEnd = true
        view.apply(settings: settings)
        #expect(maxOffset(clip) <= clip.bounds.height / 2 + 1)
    }
}
