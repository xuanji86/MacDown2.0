import AppKit
import Combine
import EditorKit
import SwiftUI

/// `EditorKit.MarkdownTextView` (TextKit 2, tree-sitter highlighting) in SwiftUI. Typing flows model-ward through the
/// delegate; the model flows back only when something other than the editor changed it (see `ExternalTextSync`).
struct EditorPane: NSViewRepresentable {
    let document: MarkdownDocument  // deliberately not @ObservedObject: no SwiftUI update per keystroke
    let scrollSync: ScrollSyncController
    // Only these keys re-evaluate the view (never typing). The system scheme is the window's: only the text view's own
    // chrome is forced to the theme's appearance, so it does not feed back.
    @AppStorage(AppearanceKey.editorTheme) private var themeName = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var followsSystem = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: EditorTheme {
        ThemeLibrary.resolve(name: themeName, followSystem: followsSystem, systemIsDark: colorScheme == .dark)
    }
    /// Lets the toolbar and menus reach the text view this pane creates.
    var editor: EditorHandle?
    /// Receives caret and selection changes for the status bar and outline.
    var status: EditorStatus?

    func makeCoordinator() -> Coordinator { Coordinator(document: document, scrollSync: scrollSync) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.makeScrollView(theme: theme)
        textView.delegate = context.coordinator
        textView.string = document.text
        context.coordinator.textView = textView
        scrollSync.attach(editor: textView)
        editor?.textView = textView
        context.coordinator.status = status
        status?.selectionChanged(in: textView)  // the caret is not necessarily at 1:1 after loading the text
        context.coordinator.observeDocument()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Called by SwiftUI after make, on environment changes (this is where the document's UndoManager arrives) and
        // when it hands the view a different document instance (Revert To / Browse All Versions).
        context.coordinator.undoManager = context.environment.undoManager
        context.coordinator.bind(to: document)
        if let textView = context.coordinator.textView, textView.theme.name != theme.name { textView.theme = theme }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private(set) var document: MarkdownDocument
        weak var textView: MarkdownTextView?
        var undoManager: UndoManager?
        var status: EditorStatus?
        private var sync: ExternalTextSync
        private var subscription: AnyCancellable?

        private let scrollSync: ScrollSyncController

        init(document: MarkdownDocument, scrollSync: ScrollSyncController) {
            self.document = document
            self.scrollSync = scrollSync
            sync = ExternalTextSync(document: document, text: document.text)
        }

        /// Point at `document` (it may be a new instance) and load its text if the editor does not already show it.
        func bind(to document: MarkdownDocument) {
            if !sync.isSameDocument(document) {
                self.document = document
                observeDocument()
            }
            reloadIfModelChanged(document.text)
        }

        /// `updateNSView` only runs when SwiftUI re-evaluates the view, which typing deliberately does not trigger, so
        /// changes of `text` on the same instance are watched here. `$text` publishes before the value is stored,
        /// hence the new value comes from the sink, not from `document.text`.
        func observeDocument() {
            subscription = document.$text.sink { [weak self] newText in
                MainActor.assumeIsolated { self?.reloadIfModelChanged(newText) }
            }
        }

        private func reloadIfModelChanged(_ modelText: String) {
            guard let text = sync.reloadText(document: document, modelText: modelText), let textView else { return }
            // Same as NSDocument revert: edits registered against the old text must not be replayed on the new one.
            undoManager?.removeAllActions()
            textView.reloadText(text)
        }

        /// Registering edits with the document's UndoManager is what makes SwiftUI mark it dirty and autosave.
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            scrollSync.caretMoved(in: textView)
            status?.selectionChanged(in: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // IME composition: the model gets the text once the marked range is committed (textDidChange fires again).
            guard !textView.hasMarkedText() else { return }
            let text = textView.string
            sync.editorDidWrite(text)  // before the write: the `$text` sink fires synchronously and must see it as ours
            document.text = text
        }
    }
}
