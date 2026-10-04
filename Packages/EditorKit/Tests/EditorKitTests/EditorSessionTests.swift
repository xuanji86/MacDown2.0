import AppKit
import Combine
import Testing
@testable import EditorKit

/// A document as the app has it: the text model, its own undo manager, a flag for "edited".
@MainActor
private final class FakeDocument: EditorDocument {
    @Published var text: String
    var textChanges: AnyPublisher<String, Never> { $text.eraseToAnyPublisher() }
    let undo = UndoManager()
    var undoManager: UndoManager? { undo }
    var userEdits = 0
    init(_ text: String) { self.text = text }
    func noteUserEdit() { userEdits += 1 }
}

/// What the app's `EditorPane.Coordinator` is for one window: the text view's delegate, handing everything to the session.
@MainActor
private final class Editor: NSObject, NSTextViewDelegate {
    let view: MarkdownTextView
    let session: EditorSession
    var userEdits = 0

    init(showing document: FakeDocument) {
        view = ViewTests.makeSizedView("")
        session = EditorSession(textView: view)
        super.init()
        view.delegate = self
        session.onUserEdit = { [unowned self] in userEdits += 1 }
        session.show(document)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { session.undoManager }
    func textDidChange(_ notification: Notification) { session.textDidChange() }

    func type(_ s: String, at location: Int? = nil) {
        view.setSelectedRange(NSRange(location: location ?? view.string.utf16.count, length: 0))
        view.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// What the text layout shows (not just the storage).
    var laidOutText: String {
        guard let layout = view.textLayoutManager else { return "" }
        var out = ""
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph { out += paragraph.attributedString.string }
            return true
        }
        return out
    }
}

/// Each document's undo steps stay on that document, whichever tab or window shows what (the P0), and a second window on the
/// same document neither erases nor breaks the history (the P1).
@MainActor
struct EditorSessionTests {
    /// The typing's undo group ends with its event, as it does in the app: without a turn two keystrokes are one step.
    private func endEvent() { RunLoop.current.run(until: Date()) }

    // MARK: One editor

    @Test func typingWritesTheModelAndMarksItEdited() {
        let doc = FakeDocument("alpha")
        let editor = Editor(showing: doc)
        #expect(editor.view.string == "alpha")
        editor.type("X")
        #expect(doc.text == "alphaX")
        #expect(doc.userEdits == 1 && editor.userEdits == 1)
        #expect(doc.undo.canUndo)
    }

    @Test func undoAndRedoReachTheModel() {
        let doc = FakeDocument("alpha")
        let editor = Editor(showing: doc)
        editor.type("X")
        endEvent()
        doc.undo.undo()
        #expect(editor.view.string == "alpha" && doc.text == "alpha")
        doc.undo.redo()
        #expect(editor.view.string == "alphaX" && doc.text == "alphaX")
    }

    @Test func switchingTabsKeepsEachDocumentsTextSelectionAndUndo() {
        let a = FakeDocument("alpha"), b = FakeDocument("beta")
        let editor = Editor(showing: a)
        editor.type("X")
        endEvent()
        editor.view.setSelectedRange(NSRange(location: 2, length: 1))
        editor.session.show(b)
        #expect(editor.view.string == "beta" && editor.laidOutText == "beta")
        editor.type("Y")
        endEvent()
        #expect(b.text == "betaY" && a.text == "alphaX")

        editor.session.show(a)
        #expect(editor.view.string == "alphaX" && editor.laidOutText == "alphaX")
        #expect(editor.view.selectedRange() == NSRange(location: 2, length: 1), "the caret is where it was left")
        a.undo.undo()
        #expect(a.text == "alpha" && editor.view.string == "alpha")
        #expect(b.text == "betaY", "the other document's text and history are untouched")
        #expect(b.undo.canUndo)

        editor.session.show(b)
        #expect(editor.view.string == "betaY")
        b.undo.undo()
        #expect(b.text == "beta" && a.text == "alpha")
    }

    // MARK: P0: an undo recorded in one window must not change another document

    @Test func anUndoFromAnotherWindowNeverEditsTheDocumentTheRecordingWindowShowsNow() {
        let a = FakeDocument("alpha"), b = FakeDocument("beta, which is longer than alpha")
        let first = Editor(showing: a)
        first.type("X")  // an undo step for A, recorded against what window 1 had on screen
        endEvent()
        first.session.show(b)  // window 1 moves on to B

        let second = Editor(showing: a)  // window 2 opens A
        #expect(second.view.string == "alphaX")
        a.undo.undo()  // Undo in window 2

        #expect(a.text == "alpha", "A is undone")
        #expect(second.view.string == "alpha" && second.laidOutText == "alpha", "and window 2 shows it")
        #expect(b.text == "beta, which is longer than alpha", "B is not touched")
        #expect(first.view.string == b.text && first.laidOutText == b.text, "nor what window 1 shows")

        a.undo.redo()
        #expect(a.text == "alphaX" && second.view.string == "alphaX")
        #expect(b.text == "beta, which is longer than alpha" && first.view.string == b.text)

        first.session.show(a)  // window 1 comes back to A: it is up to date
        #expect(first.view.string == "alphaX")
    }

    @Test func anUndoReachingAStorageNobodyShowsStillUpdatesTheModel() {
        let a = FakeDocument("alpha"), b = FakeDocument("beta")
        let editor = Editor(showing: a)
        editor.type("X")
        endEvent()
        editor.session.show(b)  // A is on screen nowhere
        a.undo.undo()
        #expect(a.text == "alpha", "the document follows the undo even though no editor shows it")
        #expect(a.userEdits == 2, "and is marked edited by it, like any other change")
        #expect(editor.userEdits == 1, "the tab that is on screen is not the one that was edited")
        #expect(editor.view.string == "beta")
        editor.session.show(a)
        #expect(editor.view.string == "alpha" && editor.laidOutText == "alpha")
    }

    // MARK: P1: two windows on one document

    @Test func aSecondEditorOnTheSameDocumentSeesTheTypingAndKeepsTheHistory() {
        let doc = FakeDocument("alpha")
        let first = Editor(showing: doc), second = Editor(showing: doc)
        first.type("X")
        endEvent()
        #expect(second.view.string == "alphaX" && second.laidOutText == "alphaX")
        #expect(doc.undo.canUndo, "window 2 hearing about window 1's typing is not a reload: the history stays")
        second.type("Y")
        endEvent()
        #expect(first.view.string == "alphaXY" && first.laidOutText == "alphaXY")
        #expect(doc.text == "alphaXY")
        #expect(first.userEdits == 1 && second.userEdits == 1, "each window pins only its own edits")
    }

    @Test func undoAndRedoWorkFromEitherWindowAcrossBothWindowsEdits() {
        let doc = FakeDocument("alpha")
        let first = Editor(showing: doc), second = Editor(showing: doc)
        first.type("X")
        endEvent()
        second.type("Y")
        endEvent()
        first.type("Z")
        endEvent()
        #expect(doc.text == "alphaXYZ")

        // Undo "from window 2": the steps were recorded alternately in both windows; both follow each one.
        for expected in ["alphaXY", "alphaX", "alpha"] {
            doc.undo.undo()
            #expect(doc.text == expected)
            #expect(first.view.string == expected && first.laidOutText == expected)
            #expect(second.view.string == expected && second.laidOutText == expected)
        }
        for expected in ["alphaX", "alphaXY", "alphaXYZ"] {
            doc.undo.redo()
            #expect(doc.text == expected)
            #expect(first.view.string == expected && second.view.string == expected)
        }
    }

    @Test func aTabSwitchInOneWindowDoesNotDisturbTheOtherWindowsUndo() {
        let a = FakeDocument("alpha"), b = FakeDocument("beta")
        let first = Editor(showing: a), second = Editor(showing: a)
        second.type("Y")
        endEvent()
        first.type("X")
        endEvent()
        first.session.show(b)  // window 1 leaves A while both windows' steps are on A's stack
        a.undo.undo()  // X: recorded in window 1, replayed with window 1 showing B
        #expect(a.text == "alphaY" && second.view.string == "alphaY" && first.view.string == "beta")
        a.undo.undo()  // Y: window 2's
        #expect(a.text == "alpha" && second.view.string == "alpha" && b.text == "beta")
        first.session.show(a)
        #expect(first.view.string == "alpha")
    }

    // MARK: Changes that are not the editor's

    @Test func aChangeOfTheModelReachesEveryStorageAndLeavesTheHistoryToTheDocument() {
        let a = FakeDocument("alpha"), b = FakeDocument("beta")
        let first = Editor(showing: a), second = Editor(showing: a)
        first.type("X")
        endEvent()
        first.session.show(b)
        a.text = "reloaded from disk"  // what `MarkdownDocument.read` does on a revert, then it clears the undo stack itself
        #expect(second.view.string == "reloaded from disk" && second.laidOutText == "reloaded from disk")
        #expect(doc(a, hasUndo: true), "the session does not decide when history is cleared")
        a.undo.removeAllActions()
        first.session.show(a)  // the storage window 1 kept for A followed along
        #expect(first.view.string == "reloaded from disk" && first.laidOutText == "reloaded from disk")
        first.type("!")
        #expect(a.text == "reloaded from disk!" && second.view.string == "reloaded from disk!")
    }

    private func doc(_ d: FakeDocument, hasUndo: Bool) -> Bool { d.undo.canUndo == hasUndo }

    @Test func compositionIsNotPublishedUntilItIsCommitted() {
        let doc = FakeDocument("a ")
        let editor = Editor(showing: doc)
        editor.view.setSelectedRange(NSRange(location: 2, length: 0))
        editor.view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.view.hasMarkedText())
        #expect(doc.text == "a ", "the model waits for the committed text")
        editor.view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(doc.text == "a 中")
    }

    // MARK: Lifetime

    @Test func closingTheWindowTakesItsStoragesUndoStepsAndStopsFollowingTheModel() {
        let doc = FakeDocument("alpha")
        let first = Editor(showing: doc), second = Editor(showing: doc)
        first.type("X")
        endEvent()
        first.session.close()
        #expect(!doc.undo.canUndo, "a step aimed at a storage that no longer follows the model would edit text that is not there")
        doc.text = "other"
        #expect(second.view.string == "other")
        second.type("!")
        #expect(doc.text == "other!")
        doc.undo.undo()  // window 2's own step still works
        #expect(doc.text == "other" && second.view.string == "other")
    }

    @Test func aClosedDocumentIsNotKeptAliveByTheWindow() async throws {
        var closed: Watch?
        let editor = Editor(showing: FakeDocument("one"))
        autoreleasepool {
            let doc = FakeDocument("two")
            closed = Watch(doc)
            editor.session.show(doc)
            editor.session.show(FakeDocument("three"))
        }
        #expect(try await closed?.freed() == true)
    }
}
