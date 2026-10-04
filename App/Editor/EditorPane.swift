import AppKit
import Combine
import EditorKit
import ExtensionAPI
import MarkdownCore
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
    var onUserEdit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(document: document, scrollSync: scrollSync) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.makeScrollView(theme: theme)
        textView.delegate = context.coordinator
        textView.behavior = settings.behavior
        textView.string = document.text
        context.coordinator.textView = textView
        scrollSync.attach(editor: textView)
        editor?.textView = textView
        context.coordinator.status = status
        context.coordinator.undoManager = document.undoManager
        status?.selectionChanged(in: textView)  // the caret is not necessarily at 1:1 after loading the text
        context.coordinator.observeDocument()
        context.coordinator.editor = editor
        editor?.documentBound(key: document.fileURL?.fileKey)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Called by SwiftUI after make, and when the window shows another tab's document (the editor is reused, only its
        // text changes). The undo manager is the document's own: every document keeps its undo stack across tab switches.
        context.coordinator.onUserEdit = onUserEdit
        context.coordinator.bind(to: document)
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private(set) var document: MarkdownDocument
        weak var textView: MarkdownTextView?
        var undoManager: UndoManager?
        var onUserEdit: (() -> Void)?
        var status: EditorStatus?
        var editor: EditorHandle?
        var decoratedFlavor: FlavorID?
        private var sync: ExternalTextSync
        private var subscription: AnyCancellable?

        private let scrollSync: ScrollSyncController

        init(document: MarkdownDocument, scrollSync: ScrollSyncController) {
            self.document = document
            self.scrollSync = scrollSync
            sync = ExternalTextSync(document: document, text: document.text)
        }

        /// Selection of each document the editor has shown, so a tab comes back with its caret where it was left.
        private var selections: [ObjectIdentifier: NSRange] = [:]

        /// Point at `document` and load its text if the editor does not already show it. A different instance is a tab
        /// switch: the text view swaps to that document's text and undo manager (nothing is cleared: the text the stack
        /// was recorded against is exactly what comes back).
        func bind(to document: MarkdownDocument) {
            if !sync.isSameDocument(document) {
                if let textView { selections[ObjectIdentifier(self.document)] = textView.selectedRange() }
                self.document = document
                undoManager = document.undoManager
                sync = ExternalTextSync(document: document, text: document.text)
                observeDocument()
                if let textView {
                    textView.reloadText(document.text)
                    let saved = selections[ObjectIdentifier(document)] ?? NSRange(location: 0, length: 0)
                    let length = (textView.string as NSString).length
                    textView.setSelectedRange(NSRange(location: min(saved.location, length), length: min(saved.length, max(0, length - saved.location))))
                    textView.scroll(toLine: 0)
                    textView.scrollRangeToVisible(textView.selectedRange())
                    status?.selectionChanged(in: textView)
                }
                editor?.documentBound(key: document.fileURL?.fileKey)  // a search result may be waiting for this file
                return
            }
            undoManager = document.undoManager
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
            // Keeps the first visible source line, not the pixel offset: an external change above the viewport changes
            // heights. The selection is remapped by `reloadText` (clamped when its text is gone).
            let line = textView.topVisibleLine
            textView.reloadText(text)
            textView.scroll(toLine: line)
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
            document.noteUserEdit()
            onUserEdit?()
        }
    }
}
