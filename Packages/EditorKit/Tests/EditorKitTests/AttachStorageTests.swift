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

    /// The tab-switch hang: away from a text longer than the window (laid out only partly), the layout manager kept that text's
    /// heights with the storage swapped under it, and the highlighter's visible-range lookup in `attach` never returned. A time
    /// limit cannot stop a blocked main actor: this test hangs rather than fails if that comes back.
    @Test(.timeLimit(.minutes(1))) func switchingBackToALaidOutTextReturns() throws {
        for lines in [30, 40, 60, 200] {
            let view = makeView((1...lines).map { "- line \($0)" }.joined(separator: "\n") + "\n")
            let scrollView = try #require(view.enclosingScrollView)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 682), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.displayIfNeeded()
            let long = try #require(view.textStorage)
            view.attach(storage: view.makeStorage(text: "# A\n\nalpha\n"))
            window.displayIfNeeded()
            #expect(view.visibleCharacterRange != nil)
            view.attach(storage: long)
            window.displayIfNeeded()
            #expect(view.visibleCharacterRange != nil)
        }
    }

    /// Both directions between short and long texts (list items, paragraphs, long wrapped paragraphs), each shown scrolled halfway
    /// first. The text switched to is laid out as in a view that never showed another one, and highlighted where the window is.
    @Test(.timeLimit(.minutes(1))) func switchingBetweenScrolledTextsLaysOutAndHighlightsTheTextShown() async throws {
        let texts = [
            (1...40).map { "- line \($0)" }.joined(separator: "\n") + "\n",
            (1...40).map { "Paragraph *\($0)*." }.joined(separator: "\n\n") + "\n",
            "# A\n\nalpha\n",
            (1...200).map { "Paragraph *\($0)* " + String(repeating: "word ", count: 30) }.joined(separator: "\n\n") + "\n",
        ]
        let short = 2
        func inWindow(_ view: MarkdownTextView) throws -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 682), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = try #require(view.enclosingScrollView)
            window.displayIfNeeded()
            return window
        }
        // The short text laid out in a view that never showed another one.
        let fresh = makeView(texts[short])
        let expected = try withExtendedLifetime(try inWindow(fresh)) { try #require(fresh.textLayoutManager).usageBoundsForTextContainer }

        let view = makeView(texts[0])
        let window = try inWindow(view)
        let layout = try #require(view.textLayoutManager)
        let storages = [try #require(view.textStorage)] + texts.dropFirst().map(view.makeStorage)
        // A character in `range` the highlighter colours, and its colour.
        func painted(in range: NSRange) -> (location: Int, color: NSColor?)? {
            let text = view.string as NSString
            for (needle, offset, kind) in [("- ", 0, TokenKind.listMarker), ("*", 1, .emphasis), ("# ", 2, .heading)] {
                let found = text.range(of: needle, range: range)
                if found.location != NSNotFound { return (found.location + offset, view.theme.tokens[kind]?.color) }
            }
            return nil
        }

        for from in storages.indices {
            for to in storages.indices where to != from {
                let comment: Comment = "from \(from) to \(to)"
                view.attach(storage: storages[from])
                window.displayIfNeeded()
                view.scroll(toLine: Double(view.lineCount / 2))
                window.displayIfNeeded()
                view.attach(storage: storages[to])
                window.displayIfNeeded()
                let range = try #require(view.visibleCharacterRange, comment)
                #expect(range.length > 0 && NSMaxRange(range) <= storages[to].length, comment)
                // Nothing of the text before is left in the heights. (TextKit can keep an earlier text's widest line as the width,
                // also with a fresh content storage; a view that does not resize horizontally ignores it.)
                if to == short {
                    let used = layout.usageBoundsForTextContainer
                    #expect(used.minY == expected.minY && used.height == expected.height, comment)
                }
                let sample = try #require(painted(in: range), comment)
                #expect(await eventually { view.textStorage?.attribute(.foregroundColor, at: sample.location, effectiveRange: nil) as? NSColor == sample.color }, comment)
            }
        }
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
