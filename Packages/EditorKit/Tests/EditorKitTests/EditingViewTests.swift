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

    // MARK: Input methods and dead keys

    private let noRange = NSRange(location: NSNotFound, length: 0)

    /// Starts an input-method composition ("n" marked) at the caret of `marked`.
    private func composing(_ marked: String, preedit: String = "n") -> MarkdownTextView {
        let view = makeView(marked)
        view.setMarkedText(preedit, selectedRange: NSRange(location: preedit.utf16.count, length: 0), replacementRange: noRange)
        #expect(view.hasMarkedText(), "headless NSTextView should accept marked text")
        return view
    }

    @Test func noPairIsInsertedWhileComposingForAnyOpenerOrCloser() {
        for c in ["(", "[", "{", "\"", "'", "`", "*", "_"] {
            let view = composing("a |")
            type(c, in: view)  // what a committing input method does: insertText over the marked range
            #expect(view.string == "a \(c)", "\(c)")
            #expect(!view.hasMarkedText())
        }
        // A closer does not step over a closer that happens to follow the composition.
        let view = composing("(|)")
        type(")", in: view)
        #expect(view.string == "())")
    }

    @Test func listContinuationAndBackspacePairingStayOutWhileComposing() {
        for (marked, forbidden) in [("1. a|", "\n2. "), ("> q|", "\n> "), ("- [ ] t|", "\n- [ ] ")] {
            let view = composing(marked)
            view.insertNewline(nil)
            #expect(!view.string.contains(forbidden), "\(marked)")
        }
        // Backspace inside an empty pair while composing is the input method's (it edits the preedit), not a pair removal.
        let view = composing("(|)")
        view.deleteBackward(nil)
        #expect(view.string.hasSuffix(")") && view.string.hasPrefix("("))
    }

    @Test func smartHomeStaysOutWhileComposing() {
        for move in [{ (v: MarkdownTextView) in v.moveToLeftEndOfLine(nil) }, { $0.moveToBeginningOfLine(nil) }] {
            let view = composing("    foo|", preedit: "ni")  // the caret ends up after the preedit; moving the selection by hand would end the composition
            #expect(view.selectedRange().length == 0 && view.selectedRange().location > 4)
            move(view)
            // Smart Home would stop at the first non-blank (4); during composition the system move wins.
            #expect(view.selectedRange().location == 0)
        }
        // Control: the same line without a composition does stop at 4 first.
        let view = makeView("    foo|")
        view.moveToLeftEndOfLine(nil)
        #expect(view.selectedRange().location == 4)
    }

    @Test func deadKeyProducesTheAccentedLetterAndNeverAPair() {
        // Option-E, then e: the dead key marks the acute accent, the next key replaces it with the composed letter.
        for replacement in [noRange, NSRange(location: 0, length: 1)] {
            let view = makeView("|")
            view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
            #expect(view.hasMarkedText())
            view.insertText("é", replacementRange: replacement)
            #expect(view.string == "é")
            #expect(!view.hasMarkedText())
        }
        // US-International style dead keys that are pairable characters (' " `): followed by space they type the character itself, once.
        for c in ["'", "\"", "`", "^", "~"] {
            let view = makeView("a |")
            view.setMarkedText(c, selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
            view.insertText(c, replacementRange: noRange)
            #expect(view.string == "a \(c)", "dead \(c)")
        }
        // ...and a dead key before a letter that composes (' + e) leaves just the letter.
        let view = makeView("a |")
        view.setMarkedText("'", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.insertText("é", replacementRange: noRange)
        #expect(view.string == "a é")
    }

    // MARK: Auto-pair: one backspace or one undo takes the pair back

    @Test func oneBackspaceRemovesTheWholeFreshPair() {
        for c in ["(", "[", "{", "\"", "'", "`", "_", "*"] {
            let view = makeView("a |")
            type(c, in: view)
            #expect(view.string.utf16.count == 4, "\(c) paired")
            view.deleteBackward(nil)
            #expect(state(view) == "a |", "\(c)")
        }
    }

    @Test func oneUndoRemovesTheWholeFreshPair() {
        for c in ["(", "\"", "`"] {
            let view = makeView("a |")
            type(c, in: view)
            #expect(view.string.utf16.count == 4)
            undo.manager.undo()
            #expect(view.string == "a ", "\(c)")
        }
    }

    @Test func backspaceAfterTypingInsideThePairStillOnlyDeletesOneCharacter() {
        let view = makeView("|")
        type("(", in: view)
        type("x", in: view)
        view.deleteBackward(nil)
        #expect(state(view) == "(|)")
        view.deleteBackward(nil)
        #expect(state(view) == "|")
    }
}
