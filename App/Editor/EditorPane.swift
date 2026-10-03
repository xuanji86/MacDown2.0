import AppKit
import SwiftUI

/// Plain-text TextKit 2 editor. Typing flows model-ward through the delegate only; the view never re-reads
/// `document.text` after `makeNSView`, so a keystroke does not copy the whole text back and forth.
/// Never use the TextKit 1 layout-manager accessor here: touching it silently downgrades the view to TextKit 1 (guarded by `make test`).
struct EditorPane: NSViewRepresentable {
    let document: MarkdownDocument  // deliberately not @ObservedObject: no SwiftUI update per keystroke

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        assert(textView.textLayoutManager != nil, "editor must be backed by TextKit 2")
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Source text: no typographic rewriting.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = document.text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Called by SwiftUI after make and on environment changes; this is where the document's UndoManager arrives.
        context.coordinator.undoManager = context.environment.undoManager
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: MarkdownDocument
        var undoManager: UndoManager?

        init(document: MarkdownDocument) { self.document = document }

        /// Registering edits with the document's UndoManager is what makes SwiftUI mark it dirty and autosave.
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // IME composition: the model gets the text once the marked range is committed (textDidChange fires again).
            guard !textView.hasMarkedText() else { return }
            document.text = textView.string
        }
    }
}
