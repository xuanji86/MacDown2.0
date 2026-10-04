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
