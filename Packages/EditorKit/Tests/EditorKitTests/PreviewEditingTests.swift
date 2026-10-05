import AppKit
import Testing
@testable import EditorKit

@MainActor
private final class Delegate: NSObject, NSTextViewDelegate {
    let undo = UndoManager()
    var changes = 0
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func textDidChange(_ notification: Notification) { changes += 1 }
}

/// Edits that come from the preview (`typeExternally`) behave like typing in the editor: the same undo steps, the same delegate
/// calls, none of the typing assistant or the system's substitutions; and the other pane's selection (`showPeerHighlight`) is drawn
/// without touching the text, the undo history or an input method's composition.
@MainActor
struct PreviewEditingTests {
    /// The typing's undo group ends with its event, as it does in the app.
    private func endEvent() { RunLoop.current.run(until: Date()) }

    private func view(_ text: String) -> (MarkdownTextView, Delegate) {
        let view = ViewTests.makeSizedView(text)
        let delegate = Delegate()
        view.delegate = delegate
        return (view, delegate)
    }

    @Test func editsAtTheCaretAreOneTypingStepLikeKeystrokes() {
        let (v, d) = view("hello world")
        #expect(v.typeExternally("a", replacing: NSRange(location: 5, length: 0), startsNewStep: true))
        endEvent()
        #expect(v.typeExternally("b", replacing: NSRange(location: 6, length: 0), startsNewStep: false))
        endEvent()
        #expect(v.typeExternally("", replacing: NSRange(location: 6, length: 1), startsNewStep: false))  // a backspace
        endEvent()
        #expect(v.typeExternally("中文", replacing: NSRange(location: 6, length: 0), startsNewStep: false))  // an input method's commit
        endEvent()
        #expect(v.string == "helloa中文 world")
        #expect(d.changes == 4)
        #expect(d.undo.undoActionName == v.undoManager?.undoActionName)
        d.undo.undo()
        endEvent()
        #expect(v.string == "hello world")
        #expect(!d.undo.canUndo)
        d.undo.redo()
        endEvent()
        #expect(v.string == "helloa中文 world")
    }

    @Test func aNewBurstOrAnotherPlaceIsANewStep() {
        let (v, d) = view("hello world")
        v.setSelectedRange(NSRange(location: 11, length: 0))
        v.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))  // typed in the editor
        endEvent()
        #expect(v.typeExternally("X", replacing: NSRange(location: 12, length: 0), startsNewStep: true))
        endEvent()
        #expect(v.typeExternally("Y", replacing: NSRange(location: 0, length: 0), startsNewStep: false))  // somewhere else
        endEvent()
        #expect(v.string == "Yhello world!X")
        d.undo.undo()
        #expect(v.string == "hello world!X")
        d.undo.undo()
        #expect(v.string == "hello world!")
        d.undo.undo()
        #expect(v.string == "hello world")
    }

    @Test func noAssistantAndNoSubstitutions() {
        let (v, _) = view("- item")
        v.behavior.autoPair = true
        v.isAutomaticQuoteSubstitutionEnabled = true
        v.isAutomaticDashSubstitutionEnabled = true
        #expect(v.typeExternally("(", replacing: NSRange(location: 6, length: 0), startsNewStep: true))
        #expect(v.typeExternally("\"--", replacing: NSRange(location: 7, length: 0), startsNewStep: false))
        #expect(v.string == "- item(\"--")
        // the user's settings are back
        #expect(v.isAutomaticQuoteSubstitutionEnabled && v.isAutomaticDashSubstitutionEnabled)
    }

    @Test func refusedWithMarkedTextOutsideTheTextOrInsideASurrogatePair() {
        let (v, d) = view("a😀b")
        #expect(!v.typeExternally("x", replacing: NSRange(location: 2, length: 0), startsNewStep: true))  // between the halves of 😀
        #expect(!v.typeExternally("", replacing: NSRange(location: 1, length: 1), startsNewStep: true))
        #expect(!v.typeExternally("x", replacing: NSRange(location: 3, length: 2), startsNewStep: true))  // past the end
        #expect(v.typeExternally("", replacing: NSRange(location: 1, length: 2), startsNewStep: true))  // all of it
        #expect(v.string == "ab")
        v.setSelectedRange(NSRange(location: 1, length: 0))
        v.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(v.hasMarkedText())
        let before = d.changes
        #expect(!v.typeExternally("x", replacing: NSRange(location: 0, length: 0), startsNewStep: true))
        #expect(d.changes == before && v.hasMarkedText())
    }

    @Test func theViewDoesNotScroll() {
        let text = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let (v, _) = view(text)
        v.scroll(toLine: 10)
        let origin = v.enclosingScrollView!.contentView.bounds.origin
        let far = (text as NSString).length - 3
        #expect(v.typeExternally("Z", replacing: NSRange(location: far, length: 0), startsNewStep: true))
        #expect(v.enclosingScrollView!.contentView.bounds.origin == origin)
    }

    /// A highlight over a whole long document looks at what is on screen only: a rectangle per visible line, not per line of the text.
    @Test func thePeerHighlightOfALongRangeCostsTheScreenOnly() {
        let text = (0..<3000).map { "line number \($0) of a long document" }.joined(separator: "\n")
        let (v, _) = view(text)
        v.showPeerHighlight([NSRange(location: 0, length: (text as NSString).length)])
        let rects = v.peerHighlightRects
        #expect(!rects.isEmpty && rects.count < 200)
        #expect(rects.allSatisfy { $0.intersects(v.visibleRect) })
    }

    @Test func thePeerHighlightTouchesNeitherTheTextNorTheUndoHistoryNorAComposition() async {
        let (v, d) = view("first line\nsecond line\n")
        _ = await eventually { v.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil }
        let attributes = v.textStorage!.attributes(at: 2, effectiveRange: nil).count
        v.showPeerHighlight([NSRange(location: 2, length: 12)])
        #expect(v.peerHighlightRanges == [NSRange(location: 2, length: 12)])
        #expect(v.peerHighlightRects.count == 2)  // over two lines
        #expect(v.textStorage!.attributes(at: 2, effectiveRange: nil).count == attributes)
        #expect(!d.undo.canUndo && d.changes == 0)
        // while an input method composes
        v.setSelectedRange(NSRange(location: 5, length: 0))
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        v.showPeerHighlight([NSRange(location: 0, length: 3)])
        #expect(v.hasMarkedText())
        v.clearPeerHighlight()
        #expect(v.peerHighlightRanges.isEmpty && v.peerHighlightRects.isEmpty)
        #expect(v.hasMarkedText())
    }
}
