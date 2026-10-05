import AppKit
import Combine
import EditorKit
import ExtensionAPI
import MarkdownCore
import SwiftUI

/// `EditorKit.MarkdownTextView` (TextKit 2, tree-sitter highlighting) in SwiftUI. One view per window, reused across tabs:
/// the `EditorSession` keeps a text storage per document and swaps the one on screen, so an undo step can only ever change the
/// document it was recorded in. Typing flows model-ward through the delegate; the model flows back into every storage of a
/// document only when something other than that storage changed it (another window, a revert).
struct EditorPane: NSViewRepresentable {
    let document: MarkdownDocument  // deliberately not @ObservedObject: no SwiftUI update per keystroke
    let scrollSync: ScrollSyncController
    // Only these keys re-evaluate the view (never typing). The system scheme is the window's: only the text view's own
    // chrome is forced to the theme's appearance, so it does not feed back.
    @AppStorage(AppearanceKey.editorTheme) private var themeName = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var followsSystem = false
    @Environment(\.colorScheme) private var colorScheme
    private var settings = EditorSettings()

    private var theme: EditorTheme {
        settings.apply(to: ThemeLibrary.resolve(name: themeName, followSystem: followsSystem, systemIsDark: colorScheme == .dark))
    }
    /// Lets the toolbar and menus reach the text view this pane creates.
    var editor: EditorHandle?
    /// Receives caret and selection changes for the status bar and outline.
    var status: EditorStatus?
    /// The document's flavor (Quarto for a .qmd while the extension is on): its regex overlay styles the text.
    var flavor: (any DocumentFlavor)?
    /// The user changed the text (typing, paste, undo): the workspace turns a preview tab into a regular one.
    var onUserEdit: ((MarkdownDocument) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(scrollSync: scrollSync) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.makeScrollView(theme: theme)
        textView.delegate = context.coordinator
        textView.behavior = settings.behavior
        context.coordinator.textView = textView
        context.coordinator.startSession(showing: document, in: textView)
        scrollSync.attach(editor: textView)
        editor?.textView = textView
        context.coordinator.status = status
        status?.selectionChanged(in: textView)  // the caret is not necessarily at 1:1 after loading the text
        context.coordinator.editor = editor
        editor?.documentBound(key: document.fileURL?.fileKey)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Called by SwiftUI after make, and when the window shows another tab's document (the view is reused; the session
        // swaps in that document's own storage, so every document keeps its undo stack across tab switches).
        context.coordinator.onUserEdit = onUserEdit
        context.coordinator.bind(to: document)
        editor?.syncDocumentKey(document.fileURL?.fileKey)  // the same document under a new URL (first save, rename)
        guard let textView = context.coordinator.textView else { return }
        textView.behavior = settings.behavior
        textView.apply(settings: settings.view)
        if context.coordinator.decoratedFlavor != flavor?.id {
            context.coordinator.decoratedFlavor = flavor?.id
            if let flavor {
                textView.decorations = { lines, first in flavor.editorDecorations(visibleLines: lines, firstLine: first) }
            } else {
                textView.decorations = nil
            }
        }
        let theme = theme
        if textView.theme.name != theme.name || textView.theme.font != theme.font { textView.theme = theme }
    }

    /// The window is going away: its storages move to their documents, where the undo steps aimed at them still work (`EditorSession.close`).
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.session?.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: MarkdownTextView?
        /// The documents this window's editor has shown, each with its own text storage.
        private(set) var session: EditorSession?
        var onUserEdit: ((MarkdownDocument) -> Void)?
        var status: EditorStatus?
        var editor: EditorHandle?
        var decoratedFlavor: FlavorID?

        private let scrollSync: ScrollSyncController

        init(scrollSync: ScrollSyncController) {
            self.scrollSync = scrollSync
        }

        func startSession(showing document: MarkdownDocument, in textView: MarkdownTextView) {
            let session = EditorSession(textView: textView)
            session.onUserEdit = { [weak self] document in (document as? MarkdownDocument).map { self?.onUserEdit?($0) } }
            self.session = session
            session.show(document)
        }

        /// Show `document` if the editor does not already: a tab switch. The view swaps to that document's storage and
        /// selection, and its undo manager becomes the document's own (nothing is cleared: the text each stack was recorded
        /// against is exactly what comes back).
        func bind(to document: MarkdownDocument) {
            guard let session, session.document !== document else { return }
            session.show(document)
            if let textView {
                textView.clearPeerHighlight()  // it was a range of the other document's text
                textView.scroll(toLine: 0)
                textView.scrollRangeToVisible(textView.selectedRange())
                status?.selectionChanged(in: textView)
            }
            editor?.documentBound(key: document.fileURL?.fileKey)  // a search result may be waiting for this file
        }

        /// Registering edits with the document's UndoManager is what makes SwiftUI mark it dirty and autosave.
        func undoManager(for view: NSTextView) -> UndoManager? { session?.undoManager }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            scrollSync.caretMoved(in: textView)
            status?.selectionChanged(in: textView)
            // Two-way selection: only a selection the user makes here goes to the preview (an edit typed in the preview moves this
            // view's selection too, while the preview has the focus), and working here ends the preview's highlight.
            if textView.window?.firstResponder === textView, !textView.hasMarkedText() {
                textView.clearPeerHighlight()
                editor?.onSelectionChange?(textView.selectedRange())
            }
        }

        func textDidChange(_ notification: Notification) {
            (notification.object as? MarkdownTextView)?.clearPeerHighlight()  // its ranges were of the old text
            session?.textDidChange()
        }
    }
}

extension MarkdownDocument: EditorDocument {
    var textChanges: AnyPublisher<String, Never> { $text.eraseToAnyPublisher() }
}
