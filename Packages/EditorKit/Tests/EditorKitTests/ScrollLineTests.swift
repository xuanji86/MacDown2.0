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

    @Test func caretColumnCountsCharacters() {
        let view = ViewTests.makeSizedView("ab\n中文👨‍👩‍👧x\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.caretColumn == 0)
        view.setSelectedRange(NSRange(location: 2, length: 0))  // end of "ab"
        #expect(view.caretColumn == 2)
        view.setSelectedRange(NSRange(location: 3, length: 0))  // start of line 1
        #expect(view.caretColumn == 0)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))  // before the final "\n"
        #expect(view.caretColumn == 4)  // 中 文 family x
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))  // empty last line
        #expect(view.caretColumn == 0)
    }

    @Test func goToLinePlacesTheCaretAtItsStart() {
        let view = ViewTests.makeSizedView("a\nbb\n\nccc")
        view.goTo(line: 3)
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
        #expect(view.caretLine == 3)
        view.goTo(line: 99)  // past the end: the last line
        #expect(view.caretLine == 3)
    }

    @Test func revealSelectsTheMatchWithinItsLine() {
        let view = ViewTests.makeSizedView("a\nfoo bar baz\n\n中文 hit")
        view.reveal(line: 1, columns: 4..<7)
        #expect(view.selectedRange() == NSRange(location: 6, length: 3))
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "bar")
        view.reveal(line: 3, columns: 3..<6)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "hit")
        view.reveal(line: 3, columns: nil)
        #expect(view.selectedRange() == NSRange(location: 15, length: 0))
    }

    @Test func revealClampsToTheLineWhenTheFileChanged() {
        let view = ViewTests.makeSizedView("short\nnext line")
        view.reveal(line: 0, columns: 3..<40)  // the line is only 5 long now
        #expect(view.selectedRange() == NSRange(location: 3, length: 2))
        view.reveal(line: 0, columns: 30..<40)
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        view.reveal(line: 99, columns: 0..<2)  // past the end: the last line
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "ne")
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

    /// A long document of wrapping paragraphs, headings, lists and code. The caller keeps the returned scroll view alive
    /// (`makeSizedView` does not, and the sleeps in these tests would let it go).
    func deepView(sections: Int = 150) -> (view: MarkdownTextView, scrollView: NSScrollView?) {
        let section = ["## Section", "", String(repeating: "A paragraph long enough to wrap onto several rows. ", count: 6), "",
                       "- one", "- two", "", "```", "code", "```", ""]
        let view = ViewTests.makeSizedView((0..<sections).flatMap { _ in section }.joined(separator: "\n"))
        let scrollView = view.enclosingScrollView
        view.theme = EditorTheme.classic.withFont(name: "", size: 14)  // scaled headings: the line heights differ
        return (view, scrollView)
    }

    /// `scroll(toLine:)` lands within a few dozen lines of a far target (the existing test above allows 60), and from some states of
    /// the layout, right after a relayout for one, not at all: asked again it does.
    func scrollFar(_ view: MarkdownTextView, toLine line: Double) async throws -> Double {
        for _ in 0..<5 {
            view.scroll(toLine: line)
            let top = try await settledTopLine(of: view)
            if abs(top - line) < 60 { return top }
        }
        return view.topVisibleLine
    }

    /// View > Zoom swaps the theme's font size: the editor has to keep its top source line, shrinking included (it used to keep
    /// the pixel offset, which is a different line once everything above rewraps), and keep it once the highlighter has restyled
    /// the headings a moment later.
    @Test func changingTheFontSizeKeepsTheTopLine() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        for size in [28.0, 7, 14, 10.5, 14] {
            let before = try await scrollFar(view, toLine: 800)
            #expect(before > 700)
            view.theme = EditorTheme.classic.withFont(name: "", size: size)
            let after = try await settledTopLine(of: view)
            #expect(abs(after - before) <= 3, "size \(size): top line \(before) -> \(after)")
        }
    }

    /// The same font in other colours is a theme change too (a user theme edited on disk): it used to rewrite every attribute and
    /// lay the whole text out again, which lost the position in a long document.
    @Test func changingOnlyTheColoursKeepsTheTopLine() async throws {
        let (view, scrollView) = deepView(sections: 400)
        defer { withExtendedLifetime(scrollView) {} }
        let before = try await scrollFar(view, toLine: 3000)
        #expect(before > 2900)
        var recoloured = EditorTheme.classic.withFont(name: "", size: 14)
        recoloured.text = .red
        recoloured.background = .black
        view.theme = recoloured
        let after = try await settledTopLine(of: view)
        #expect(abs(after - before) <= 3, "top line \(before) -> \(after)")
    }

    /// The line is put back while the highlighter is still restyling, not for ever: a user who scrolls away keeps where they went.
    @Test func aUserScrollAfterAFontChangeIsNotUndone() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        _ = try await scrollFar(view, toLine: 800)
        view.theme = EditorTheme.classic.withFont(name: "", size: 7)
        view.goTo(line: 200)  // right away, before the highlighter is done
        let there = view.topVisibleLine
        let after = try await settledTopLine(of: view)
        #expect(abs(after - there) <= 3, "scrolled to \(there), ended at \(after)")
        #expect(abs(after - 200) < 60)
    }

    /// The same for whoever else scrolls with `scroll(toLine:)`: scroll sync from the preview, a hook.
    @Test func anExternalScrollToALineAfterAFontChangeIsNotUndone() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        _ = try await scrollFar(view, toLine: 800)
        view.theme = EditorTheme.classic.withFont(name: "", size: 7)
        #expect(view.keptTopLine != nil)
        view.scroll(toLine: 200)
        let there = view.topVisibleLine
        let after = try await settledTopLine(of: view)
        #expect(abs(after - there) <= 3, "scrolled to \(there), ended at \(after)")
        #expect(abs(after - 200) < 60)
    }

    /// The kept line lives only as long as the highlighter has work to do, and that must end whatever the last request came to: here
    /// every request fails (an input method is composing), so nothing is ever styled and nothing reports a styled chunk.
    @Test func theKeptLineIsReleasedWhenTheHighlighterFails() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        _ = try await scrollFar(view, toLine: 800)
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.theme = EditorTheme.classic.withFont(name: "", size: 7)
        #expect(view.keptTopLine != nil)
        for _ in 0..<20 where view.keptTopLine != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.keptTopLine == nil)
    }

    /// Nothing to style, nothing to wait for.
    @Test func theKeptLineIsReleasedForAnEmptyText() async throws {
        let (view, scrollView) = deepView(sections: 0)
        defer { withExtendedLifetime(scrollView) {} }
        view.theme = EditorTheme.classic.withFont(name: "", size: 7)
        for _ in 0..<20 where view.keptTopLine != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.keptTopLine == nil)
    }

    /// `scrollView` in a window, the view first responder (key events, the scroller, layout on display). Close it when done.
    func inWindow(_ scrollView: NSScrollView?, width: CGFloat = 800) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = try #require(scrollView)
        window.makeFirstResponder(scrollView?.documentView)
        window.displayIfNeeded()
        return window
    }

    /// A scroller whose last hit is set by hand: its action then does what dragging the knob does, through the scroll view's own scroller
    /// handling (a real drag runs a tracking loop on window-server events).
    final class HitScroller: NSScroller {
        override var hitPart: NSScroller.Part { .knob }
    }

    /// Ways to scroll other than `scroll(toLine:)` and the text view's range scrolling: the scroller, a page key, the scroll and Jump to
    /// Selection commands as a menu item or a key binding sends them (no key event). Each one lets the kept line go; otherwise the restyle
    /// that the scroll itself starts (newly visible text) takes the view straight back. A wheel or trackpad moves the clip view the same
    /// way (measured), but a made-up wheel event sent through the scroll view crashes the test host a turn later.
    @Test func everyOtherScrollReleasesTheKeptLine() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        let window = try inWindow(scrollView)
        defer { window.close() }
        let scroller = HitScroller()
        scrollView?.verticalScroller = scroller
        let pageDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(NSPageDownFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSPageDownFunctionKey)!),
            isARepeat: false, keyCode: 121))
        var size = 7.0
        let moves: [(String, () -> Void)] = [
            ("the scroller", { scroller.doubleValue = 0.3; NSApp.sendAction(scroller.action!, to: scroller.target, from: scroller) }),
            ("a page key", { view.keyDown(with: pageDown) }),
            ("scrollPageDown:", { view.scrollPageDown(nil) }),
            ("scrollToBeginningOfDocument:", { view.scrollToBeginningOfDocument(nil) }),
            ("Jump to Selection", { view.setSelectedRange(NSRange(location: view.offsetOfLine(200), length: 0)); view.centerSelectionInVisibleArea(nil) }),
        ]
        for (name, move) in moves {
            _ = try await scrollFar(view, toLine: 800)
            try await Task.sleep(for: .milliseconds(300))  // the previous one's highlighting is done
            size += 1
            view.theme = EditorTheme.classic.withFont(name: "", size: size)
            #expect(view.keptTopLine != nil)
            let before = view.topVisibleLine
            move()
            #expect(view.keptTopLine == nil, "\(name)")
            #expect(abs(view.topVisibleLine - before) > 1, "\(name) moved the view, and it was taken back")
        }
    }

    /// A theme change while an input method composes leaves the text alone until the composition ends (`ThemeCompositionTests`). The
    /// relayout that follows the commit keeps the top line like any other theme change (it used to keep whatever line the old pixel
    /// offset fell on: 800 -> 1586 here), and lets it go once the highlighter is done.
    @Test(arguments: [true, false]) func aFontChangeDuringACompositionKeepsTheTopLineThroughTheCommit(commitsByTyping: Bool) async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        let window = try inWindow(scrollView)
        defer { window.close() }
        let before = try await composeAndChangeTheFont(view)
        if commitsByTyping { view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { view.unmarkText() }
        #expect(!view.hasMarkedText())
        // The commit is an edit, so the highlighter's first tokens wait for the parse; the line is held until it is done.
        for _ in 0..<400 where view.keptTopLine != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.keptTopLine == nil)
        let after = try await settledTopLine(of: view)
        #expect(abs(after - before) < 0.5, "after the commit: \(before) -> \(after)")
    }

    @Test func typingAfterTheCommitReleasesTheKeptLine() async throws {
        let (view, scrollView) = deepView()
        defer { withExtendedLifetime(scrollView) {} }
        let window = try inWindow(scrollView)
        defer { window.close() }
        _ = try await composeAndChangeTheFont(view)
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.keptTopLine != nil)
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.keptTopLine == nil)
    }

    /// Scrolled far, an input method composing a few lines below the top, then a font change; returns the top line before it.
    func composeAndChangeTheFont(_ view: MarkdownTextView) async throws -> Double {
        let before = try await scrollFar(view, toLine: 800)
        view.setSelectedRange(NSRange(location: view.offsetOfLine(Int(before) + 3), length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.hasMarkedText())
        view.theme = EditorTheme.classic.withFont(name: "", size: 7)
        let composing = try await settledTopLine(of: view)
        #expect(view.hasMarkedText())
        #expect(abs(composing - before) < 0.5, "while composing: \(before) -> \(composing)")
        return before
    }

    /// The top line once two reads 0.1 s apart agree: the highlighter restyles (heading sizes) a moment after a scroll or a theme change.
    func settledTopLine(of view: MarkdownTextView) async throws -> Double {
        var last = view.topVisibleLine
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            view.window?.displayIfNeeded()
            let now = view.topVisibleLine
            if abs(now - last) < 0.01 { return now }
            last = now
        }
        return last
    }
}
