import AppKit
import ExtensionAPI
import Testing
@testable import EditorKit

/// Supplies the undo manager a window would: the one of the document being shown. Swapped by the test like the app swaps it.
@MainActor
private final class Provider: NSObject, NSTextViewDelegate {
    var manager = UndoManager()
    var changes = 0
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
    func textDidChange(_ notification: Notification) { changes += 1 }
}

/// The length of every range whose text checking results reached the view (NSTextView tells the delegate as it applies them).
@MainActor
private final class CheckedRanges: NSObject, NSTextViewDelegate {
    var lengths: [Int] = []
    func textView(
        _ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any] = [:],
        results: [NSTextCheckingResult], orthography: NSOrthography, wordCount: Int
    ) -> [NSTextCheckingResult] {
        lengths.append(range.length)
        return results
    }
}

/// One short turn of the main run loop (not callable from an async function itself).
@MainActor
private func turnRunLoop() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

/// `.timeLimit` cannot stop a main actor that is blocked: this ends the test process with the test's name instead, so a hang fails
/// `make test` within seconds rather than leaving it waiting forever.
private func watchdog(_ name: String, seconds: Double = 30) -> DispatchWorkItem {
    let item = DispatchWorkItem { fatalError("\(name) still running after \(Int(seconds)) s: the main thread is blocked") }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    return item
}

/// `MarkdownTextView.attach(storage:)`: one view, one storage per document, swapped on a tab switch. NSTextView records an undo
/// step against the storage the edit happened in, so with a storage per document an undo can only ever change its own document.
@MainActor
struct AttachStorageTests {
    private let noRange = NSRange(location: NSNotFound, length: 0)
    private let provider = Provider()

    private func makeView(_ text: String) -> MarkdownTextView {
        let view = ViewTests.makeSizedView(text)
        view.delegate = provider
        return view
    }

    private func type(_ s: String, at location: Int, in view: MarkdownTextView) {
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.insertText(s, replacementRange: noRange)
    }

    /// What the text layout (not just the storage) shows.
    private func laidOutText(_ view: MarkdownTextView) -> String {
        guard let layout = view.textLayoutManager else { return "" }
        var out = ""
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph { out += paragraph.attributedString.string }
            return true
        }
        return out
    }

    @Test func attachingShowsAnotherStorageAndLeavesTheFirstAlone() {
        let view = makeView("alpha")
        let first = view.textStorage
        let second = view.makeStorage(text: "beta")
        view.attach(storage: second)
        #expect(view.textStorage === second)
        #expect(view.string == "beta")
        #expect(laidOutText(view) == "beta")
        #expect(first?.string == "alpha")

        type("!", at: 4, in: view)  // typing goes to what is shown
        #expect(second.string == "beta!" && first?.string == "alpha")
        #expect(laidOutText(view) == "beta!")

        view.attach(storage: first!)  // and back
        #expect(view.string == "alpha")
        #expect(laidOutText(view) == "alpha")
        type("?", at: 5, in: view)
        #expect(first?.string == "alpha?" && second.string == "beta!")
        #expect(laidOutText(view) == "alpha?")
    }

    /// The defect: the undo step of an edit made in one document must not change what another document shows.
    @Test func anUndoStepChangesTheStorageItWasRecordedIn() {
        let view = makeView("alpha")
        let first = view.textStorage!
        type("X", at: 5, in: view)
        #expect(first.string == "alphaX")
        RunLoop.current.run(until: Date())  // the typing's undo group ends with its event

        let second = view.makeStorage(text: "beta")
        view.attach(storage: second)  // another tab, which shares the undo manager here to make the point
        let changesBefore = provider.changes
        provider.manager.undo()
        #expect(first.string == "alpha", "the undo reached the storage the edit was in")
        #expect(second.string == "beta" && view.string == "beta", "and not the one on screen")
        #expect(laidOutText(view) == "beta")
        #expect(provider.changes == changesBefore, "the view shows another text: nothing to announce")

        provider.manager.redo()
        #expect(first.string == "alphaX" && view.string == "beta")
    }

    @Test func aStorageEditedWhileOnScreenIsStillUndoableAfterComingBack() {
        let view = makeView("alpha")
        let first = view.textStorage!
        type("X", at: 5, in: view)
        RunLoop.current.run(until: Date())
        view.attach(storage: view.makeStorage(text: "beta"))
        view.attach(storage: first)
        let changesBefore = provider.changes
        provider.manager.undo()
        #expect(view.string == "alpha")
        #expect(laidOutText(view) == "alpha")
        #expect(provider.changes == changesBefore + 1, "on screen again: the undo is announced like any other edit")
    }

    @Test func highlightingFollowsTheStorageOnScreen() async throws {
        let view = makeView("plain\n")
        let first = view.textStorage!
        view.attach(storage: view.makeStorage(text: "# Title\n"))
        let heading = try #require(view.theme.tokens[.heading]?.color)
        #expect(await eventually { view.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == heading })
        // the old storage is not painted any more: editing it off screen restyles nothing and is not an error
        first.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor != heading)
        // back again: painted from scratch
        view.attach(storage: first)
        #expect(await eventually { first.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == heading })
    }

    @Test func aStorageSwapKeepsTheThemeAndTheFlavorOverlay() async throws {
        let view = makeView("a\n")
        view.decorations = { lines, first in lines.indices.map { DecorationSpan(line: first + $0, columns: 0..<1, token: "quartoDiv") } }
        let div = try #require(view.theme.tokens[.quartoDiv]?.color)
        let bigger = view.theme.withFont(name: "Menlo-Regular", size: 19)
        view.theme = bigger
        view.attach(storage: view.makeStorage(text: "b\n"))
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 19)
        #expect(await eventually { view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == div })
    }

    /// A window like the app's editor pane, shown (laid out and drawn); closed by the caller.
    private func inWindow(_ view: MarkdownTextView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 682), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = try #require(view.enclosingScrollView)
        window.displayIfNeeded()
        return window
    }

    private func list(_ lines: Int) -> String { (1...lines).map { "- line \($0)" }.joined(separator: "\n") + "\n" }

    /// The frames of the layout fragments from the top of the text to the one at the bottom of the window. (Further down TextKit
    /// can leave a fragment where it was first estimated, also in a view that never showed another text.)
    private func framesDownToTheWindowBottom(_ view: MarkdownTextView) -> [CGRect] {
        guard let layout = view.textLayoutManager else { return [] }
        let bottom = view.visibleRect.maxY - view.textContainerOrigin.y
        var frames: [CGRect] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            frames.append(fragment.layoutFragmentFrame)
            return fragment.layoutFragmentFrame.maxY < bottom
        }
        return frames
    }

    /// The tab-switch hang: away from a text longer than the window (laid out only partly), the layout manager kept that text's
    /// geometry with the storage swapped under it (the new text placed where the old one's laid-out part ended, the old height
    /// kept), and the highlighter's visible-range lookup in `attach` could lay out forever. None of the old geometry is left right
    /// after the switch, the short text then has the height it has in a view that never showed anything else, and back on the long
    /// text what is visible starts at its top.
    @Test(.timeLimit(.minutes(1))) func switchingAwayFromAPartlyLaidOutTextReturns() async throws {
        let dog = watchdog(#function)
        defer { dog.cancel() }
        let shortText = "# A\n\nalpha\n"
        let fresh = makeView(shortText)
        let freshWindow = try inWindow(fresh)
        defer { freshWindow.close() }
        let heading = try #require(fresh.theme.tokens[.heading]?.color)
        #expect(await eventually { fresh.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == heading })
        freshWindow.displayIfNeeded()
        let expected = try #require(fresh.textLayoutManager).usageBoundsForTextContainer

        for lines in [30, 40, 60, 200, 1000] {
            let view = makeView(list(lines))
            let window = try inWindow(view)
            defer { window.close() }
            let layout = try #require(view.textLayoutManager)
            let long = try #require(view.textStorage)
            let short = view.makeStorage(text: shortText)
            view.attach(storage: short)
            #expect(layout.usageBoundsForTextContainer.maxY <= expected.maxY + 0.5, "\(lines) lines: \(layout.usageBoundsForTextContainer)")
            window.displayIfNeeded()
            #expect(abs(layout.usageBoundsForTextContainer.height - expected.height) < 0.5, "\(lines) lines: \(layout.usageBoundsForTextContainer)")
            #expect(view.visibleCharacterRange == NSRange(location: 0, length: short.length), "\(lines) lines")
            view.attach(storage: long)
            window.displayIfNeeded()
            let range = try #require(view.visibleCharacterRange)
            #expect(range.location == 0 && NSMaxRange(range) >= view.offsetOfLine(min(lines, 20)), "\(lines) lines: \(range)")
        }
    }

    /// Both directions between short and long texts (list items, paragraphs, long wrapped paragraphs), each shown scrolled halfway
    /// first. The text switched to is shown from the top, laid out as in a view that never showed another one (nothing of the old
    /// text's geometry), and highlighted there.
    @Test(.timeLimit(.minutes(1))) func switchingBetweenScrolledTextsLaysOutAndHighlightsTheTextShown() async throws {
        let dog = watchdog(#function)
        defer { dog.cancel() }
        let texts = [
            list(40),
            (1...40).map { "Paragraph *\($0)*." }.joined(separator: "\n\n") + "\n",
            "# A\n\nalpha\n",
            (1...200).map { "Paragraph *\($0)* " + String(repeating: "word ", count: 30) }.joined(separator: "\n\n") + "\n",
        ]
        // The last character in `range` the highlighter colours (it paints the visible range from the top), and its colour.
        func painted(in range: NSRange, of view: MarkdownTextView) -> (location: Int, color: NSColor?)? {
            let text = view.string as NSString
            for (needle, offset, kind) in [("- ", 0, TokenKind.listMarker), ("*", -1, .emphasis), ("# ", 2, .heading)] {
                let found = text.range(of: needle, options: .backwards, range: range)
                if found.location != NSNotFound { return (found.location + offset, view.theme.tokens[kind]?.color) }
            }
            return nil
        }
        // Painted down to the bottom of the window, and laid out again since (painting changes the attributes of what it lays out).
        func isPainted(_ view: MarkdownTextView, in window: NSWindow) async throws -> Bool {
            let visible = try #require(view.visibleCharacterRange)
            let sample = try #require(painted(in: visible, of: view))
            let done = await eventually { view.textStorage?.attribute(.foregroundColor, at: sample.location, effectiveRange: nil) as? NSColor == sample.color }
            window.displayIfNeeded()
            return done
        }

        // Each text in a view that never showed another one, painted (a heading's size is part of the heights).
        var expected: [[CGRect]] = []
        for text in texts {
            let fresh = makeView(text)
            let window = try inWindow(fresh)
            defer { window.close() }
            #expect(try await isPainted(fresh, in: window))
            expected.append(framesDownToTheWindowBottom(fresh))
        }

        let view = makeView(texts[0])
        let window = try inWindow(view)
        defer { window.close() }
        let storages = [try #require(view.textStorage)] + texts.dropFirst().map(view.makeStorage)
        for from in storages.indices {
            for to in storages.indices where to != from {
                let comment: Comment = "from \(from) to \(to)"
                view.attach(storage: storages[from])
                window.displayIfNeeded()
                view.scroll(toLine: Double(view.lineCount / 2))
                window.displayIfNeeded()
                // The colours it kept from the last time it was shown go, so the highlighting checked below is this switch's.
                let target = storages[to]
                target.setAttributes(view.theme.baseAttributes, range: NSRange(location: 0, length: target.length))
                view.attach(storage: target)
                window.displayIfNeeded()
                let range = try #require(view.visibleCharacterRange, comment)
                #expect(range.location == 0 && range.length > 0 && NSMaxRange(range) <= target.length, comment)
                #expect(try await isPainted(view, in: window), comment)
                let frames = framesDownToTheWindowBottom(view)
                #expect(frames.count == expected[to].count, comment)
                for (got, want) in zip(frames, expected[to]) {
                    #expect(abs(got.minY - want.minY) < 0.5 && abs(got.height - want.height) < 0.5, "\(comment): \(got) vs \(want)")
                }
            }
        }
    }

    /// NSTextView scrolls to a range once it is laid out: a scroll the text before asked for and did not get to (no display since)
    /// must not move the next text to that offset.
    @Test func aScrollLeftPendingByTheTextBeforeDoesNotMoveTheNextOne() throws {
        let view = makeView(list(400))
        let window = try inWindow(view)
        defer { window.close() }
        view.scrollRangeToVisible(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        view.attach(storage: view.makeStorage(text: list(800)))
        window.displayIfNeeded()
        #expect(view.visibleCharacterRange?.location == 0)
    }

    /// The text finder caches the matches of the text it searched, which a storage swap does not reach: Replace All in the find bar
    /// then edited the next text at the old ranges and raised NSRangeException. A switch hides the bar, which ends that search.
    /// (Not driven further here: searching writes the system-wide find pasteboard.)
    @Test func aSwitchHidesTheFindBar() throws {
        let view = makeView(String(repeating: "foo bar ", count: 300))
        let window = try inWindow(view)
        defer { window.close() }
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(show)
        #expect(view.enclosingScrollView?.isFindBarVisible == true)
        view.attach(storage: view.makeStorage(text: "foo x\n"))
        #expect(view.enclosingScrollView?.isFindBarVisible == false)
    }

    /// Text checking runs in the background: results about the text that left are not applied to the one on screen (their ranges
    /// are the other text's), and the text on screen is still checked.
    @Test func textCheckingOfTheTextThatLeftIsDropped() async throws {
        // NSTextView applies the results on a turn of the main run loop, which an `await` alone does not give it; short turns, so
        // the other tests on the main actor keep running.
        func spin(_ seconds: Double, until done: () -> Bool = { false }) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline {
                turnRunLoop()
                await Task.yield()
            }
        }
        let checks = CheckedRanges()
        let view = ViewTests.makeSizedView("Hello\nI beleive teh cat is hungyr -- \"quoted\".\n")
        view.delegate = checks
        let window = try inWindow(view)
        defer { window.close() }
        // As with Edit > Spelling and Grammar and Substitutions switched on.
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        let types = NSTextCheckingResult.CheckingType([.spelling, .correction, .replacement, .quote, .dash]).rawValue
        let firstLength = view.textStorage?.length ?? 0
        view.checkText(in: NSRange(location: 0, length: firstLength), types: types, options: [:])
        let second = view.makeStorage(text: "Hello\nSecnod text, a little longer than the first one is.\n")
        view.attach(storage: second)
        // Time for the first check to come back (a few milliseconds) before the next one is asked for, which would supersede it.
        await spin(0.3)
        view.checkText(in: NSRange(location: 0, length: second.length), types: types, options: [:])
        await spin(5) { !checks.lengths.isEmpty }
        await spin(0.2)
        // Continuous checking may check the text on screen once more by itself.
        #expect(!checks.lengths.contains(firstLength) && checks.lengths.contains(second.length), "\(checks.lengths)")
    }

    /// What the preview typed is in the text that was on screen: the next text gets the system's automatic changes again.
    @Test func whatThePreviewTypedStaysWithItsText() {
        let view = makeView("hello")
        #expect(view.typeExternally("X", replacing: NSRange(location: 5, length: 0), startsNewStep: true))
        let correction = NSTextCheckingResult.correctionCheckingResult(range: NSRange(location: 0, length: 1), replacementString: "Y")
        #expect(view.automaticChangesToApply([correction]).isEmpty)
        view.attach(storage: view.makeStorage(text: "other"))
        #expect(view.automaticChangesToApply([correction]).count == 1)
    }

    /// A text that comes back with the theme it left with keeps its attributes: a heading the highlighter sized while it was on
    /// screen is still that size before it is painted again (the highlighter repaints near the top first), so heights do not jump.
    @Test func aTextComingBackKeepsTheHeadingSizesItWasGiven() async throws {
        let text = String(repeating: "a filler line with a few words in it\n", count: 300) + "# Far heading\n"
        let view = makeView(text)
        let window = try inWindow(view)
        defer { window.close() }
        let first = try #require(view.textStorage)
        let far = first.length - 4
        let size = view.theme.font.pointSize * (try #require(view.theme.tokens[.heading1]?.fontScale))
        func sizeAtFar() -> CGFloat? { (first.attribute(.font, at: far, effectiveRange: nil) as? NSFont)?.pointSize }
        view.scrollRangeToVisible(NSRange(location: far, length: 0))
        window.displayIfNeeded()
        #expect(await eventually { sizeAtFar() == size })
        view.attach(storage: view.makeStorage(text: "b\n"))
        view.attach(storage: first)
        #expect(sizeAtFar() == size)
    }

    /// A text shown again after a theme change made while it was off screen takes the theme's font everywhere, also where the
    /// highlighter does not repaint right away.
    @Test func aTextShownAfterAThemeChangeTakesTheNewFont() {
        let view = makeView(String(repeating: "some words ", count: 2000))
        let first = view.textStorage!
        view.attach(storage: view.makeStorage(text: "b\n"))
        view.theme = view.theme.withFont(name: "Menlo-Regular", size: 19)
        view.attach(storage: first)
        #expect((first.attribute(.font, at: first.length - 1, effectiveRange: nil) as? NSFont)?.pointSize == 19)
    }

    /// A view that goes away lets go of its storage without building a highlighter for the empty one.
    @Test func detachingLeavesTheViewEmptyWithoutAHighlighter() async throws {
        var shown: Watch?
        let view = makeView("alpha")
        autoreleasepool {
            let storage = view.makeStorage(text: "beta")
            shown = Watch(storage)
            view.attach(storage: storage)
        }
        view.detachStorage()
        #expect(view.string.isEmpty && view.highlighter == nil)
        #expect(try await shown?.freed() == true)
    }

    @Test func aStorageOffScreenIsFreedWhenNothingKeepsIt() async throws {
        var other: Watch?
        let view = makeView("alpha")
        autoreleasepool {
            let storage = view.makeStorage(text: "beta")
            other = Watch(storage)
            view.attach(storage: storage)
        }
        view.attach(storage: view.makeStorage(text: "gamma"))
        #expect(try await other?.freed() == true)
    }
}
