import AppKit
import Testing
@testable import EditorKit

/// Supplies the undo manager a window would (the app's coordinator does the same with the document's).
@MainActor
private final class UndoProvider: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

@MainActor
private final class ChangeSpy: NSObject, NSTextViewDelegate {
    var changes = 0
    func textDidChange(_ notification: Notification) { changes += 1 }
}

/// The overrides on the real view: they must go through the text system (undo, delegate) and stay out of the way of
/// input-method composition.
@MainActor
struct EditingViewTests {
    private let undo = UndoProvider()

    private func makeView(_ marked: String) -> MarkdownTextView {
        let m = Marked(marked)
        let view = ViewTests.makeSizedView(m.text)
        view.delegate = undo
        view.setSelectedRange(m.selection)
        return view
    }

    private func state(_ view: MarkdownTextView) -> String { Marked.render(view.string, view.selectedRange()) }

    private func type(_ s: String, in view: MarkdownTextView) {
        view.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func performIsUndoableAsOneStep() {
        let view = makeView("a ⟦word⟧ b")
        view.perform(.bold)
        #expect(state(view) == "a **⟦word⟧** b")
        undo.manager.undo()
        #expect(view.string == "a word b")
    }

    @Test func performUsesTheClipboardURL() {
        let board = NSPasteboard(name: NSPasteboard.Name("macdown2.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        let view = makeView("⟦site⟧")
        view.perform(.link, pasteboard: board)
        #expect(state(view) == "[site](https://example.com)|")
    }

    @Test func typingAnOpenerPairsAndTheCloserStepsOver() {
        let view = makeView("|")
        type("(", in: view)
        #expect(state(view) == "(|)")
        type("x", in: view)
        type(")", in: view)
        #expect(state(view) == "(x)|")
    }

    @Test func returnContinuesAListAndAnEmptyItemEndsIt() {
        let view = makeView("- a|")
        view.insertNewline(nil)
        #expect(state(view) == "- a\n- |")
        view.insertNewline(nil)
        #expect(state(view) == "- a\n|")
    }

    @Test func tabAndBacktabIndentListItems() {
        let view = makeView("- a|")
        view.insertTab(nil)
        #expect(state(view) == "    - a|")
        view.insertBacktab(nil)
        #expect(state(view) == "- a|")
    }

    @Test func backspaceRemovesAPairTogether() {
        let view = makeView("(|)")
        view.deleteBackward(nil)
        #expect(state(view) == "|")
    }

    @Test func commandsPassThroughTheDelegateLikeTyping() {
        let spy = ChangeSpy()
        let view = makeView("⟦x⟧")
        view.delegate = spy
        view.perform(.bold)
        #expect(spy.changes == 1)
    }

    /// A list item with an input method mid-composition ("ni" marked after `- a`).
    private func composing() -> MarkdownTextView {
        let view = makeView("- a|")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        return view
    }

    @Test func nothingFiresWhileAnInputMethodIsComposing() {
        let wrapped = composing()
        wrapped.perform(.bold)  // would wrap
        #expect(wrapped.string == "- ani")
        let tabbed = composing()
        tabbed.insertTab(nil)  // would indent the list item
        #expect(!tabbed.string.hasPrefix("    "))
        let broken = composing()
        broken.insertNewline(nil)  // would continue the list
        #expect(!broken.string.hasSuffix("- "))
    }

    @Test func aTypedOpenerIsNotPairedWhileComposing() {
        let view = makeView("|")
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        type("(", in: view)  // what a committing IME does: insertText over the marked range
        #expect(!view.string.contains("()"))
    }

    @Test func emojiAndCJKSurviveTheViewRoundTrip() {
        let view = makeView("😀⟦你好⟧😀")
        view.perform(.bold)
        #expect(state(view) == "😀**⟦你好⟧**😀")
        view.perform(.heading(2))
        #expect(state(view) == "## 😀**⟦你好⟧**😀")
    }

    @Test func behaviorCanDisableTheAssistant() {
        let view = makeView("|")
        view.behavior.autoPair = false
        type("(", in: view)
        #expect(state(view) == "(|")
    }
}
