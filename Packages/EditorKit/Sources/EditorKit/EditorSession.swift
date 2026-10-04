import AppKit
import Combine

/// What an editor needs from a document: its text (the model), the changes of it, and the document's own undo manager.
@MainActor
public protocol EditorDocument: AnyObject {
    var text: String { get set }
    /// Every new value of `text`, delivered synchronously before it is stored (what `@Published` gives: `$text`).
    var textChanges: AnyPublisher<String, Never> { get }
    var undoManager: UndoManager? { get }
    /// The user changed the text in an editor (typing, paste, a command, undo): mark the document edited.
    func noteUserEdit()
}

/// One window's editor view and the documents it shows.
///
/// Each document the view has shown gets a text storage of its own here, and the view swaps the storage it displays
/// (`MarkdownTextView.attach(storage:)`) when the window shows another document. NSTextView records an undo step against the
/// storage the edit happened in and an undo manager cannot retarget one, so this is what keeps every document's undo steps on
/// that document's text: with one storage reused for all tabs, an undo recorded in tab A and replayed (from another window,
/// say) while the storage holds tab B would edit B. A document shown in two windows has a storage in each; they follow the
/// model, which is the single copy that is saved and previewed:
///
///   * typing, paste, formatting, undo and redo in a storage write the document's `text`;
///   * a change of `text` that did not come from a storage (another window's edit, a revert, a reload from disk) is copied into
///     every storage of the document, on screen or not, without touching the undo history. Clearing it when the file is read
///     again is the document's job (`MarkdownDocument.read`), not a side effect of seeing a change.
///
/// Because every storage of a document equals the model whenever an undo runs, an undo step recorded in any window replays
/// correctly from any other, whichever tab that window shows at the time.
@MainActor
public final class EditorSession {
    @MainActor private final class Buffer {
        weak var document: (any EditorDocument)?
        let storage: NSTextStorage
        /// The text this storage and the model last agreed on.
        var sync: ExternalTextSync
        var selection = NSRange(location: 0, length: 0)
        var subscription: AnyCancellable?
        var observer: NSObjectProtocol?

        init(document: any EditorDocument, storage: NSTextStorage) {
            self.document = document
            self.storage = storage
            sync = ExternalTextSync(document: document, text: storage.string)
        }

        func stopObserving() {
            subscription = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        isolated deinit { stopObserving() }
    }

    private weak var textView: MarkdownTextView?
    private var buffers: [ObjectIdentifier: Buffer] = [:]
    private var shown: Buffer?

    /// The user edited the document on screen (not an undo that reached a storage off screen): the workspace turns a preview
    /// tab into a regular one.
    public var onUserEdit: (() -> Void)?

    public init(textView: MarkdownTextView) {
        self.textView = textView
    }

    /// The document on screen.
    public var document: (any EditorDocument)? { shown?.document }

    /// What the view's delegate answers to `undoManager(for:)`: the shown document's.
    public var undoManager: UndoManager? { shown?.document?.undoManager }

    // MARK: Showing a document

    /// Puts `document` on screen (its own storage, its selection from the last time). Does nothing if it already is.
    public func show(_ document: any EditorDocument) {
        guard let textView, shown?.document !== document else { return }
        shown?.selection = textView.selectedRange()
        discardBuffersOfDeadDocuments()
        let buffer = buffers[ObjectIdentifier(document)].flatMap { $0.document === document ? $0 : nil } ?? makeBuffer(for: document, in: textView)
        shown = buffer
        textView.attach(storage: buffer.storage)
        let length = buffer.storage.length
        let location = min(buffer.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(buffer.selection.length, length - location)))
    }

    private func makeBuffer(for document: any EditorDocument, in textView: MarkdownTextView) -> Buffer {
        let buffer = Buffer(document: document, storage: textView.makeStorage(text: document.text))
        buffer.subscription = document.textChanges.sink { [weak self, weak buffer] text in
            MainActor.assumeIsolated {
                if let self, let buffer { self.modelDidChange(buffer, to: text) }
            }
        }
        // Undo and redo reach a storage the view is not showing (another tab's) without any view to announce them.
        buffer.observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: buffer.storage, queue: nil) { [weak self, weak buffer] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard let self, let buffer, buffer !== self.shown,
                      let manager = buffer.document?.undoManager, manager.isUndoing || manager.isRedoing else { return }
                self.publish(buffer)
            }
        }
        buffers[ObjectIdentifier(document)] = buffer
        return buffer
    }

    private func discardBuffersOfDeadDocuments() {
        for (key, buffer) in buffers where buffer.document == nil && buffer !== shown {
            buffer.stopObserving()
            buffers[key] = nil
        }
    }

    // MARK: Text flowing between the storages and the model

    /// The view's `textDidChange`: typing, paste, a command, or an undo/redo that reached the storage on screen.
    public func textDidChange() {
        // IME composition: the model gets the text once the marked range is committed (textDidChange fires again).
        guard let shown, let textView, !textView.hasMarkedText() else { return }
        if publish(shown) { onUserEdit?() }
    }

    /// Storage -> model. False when the model already had this text (a copy of the model that was just written into the
    /// storage, or an edit that changed no characters).
    @discardableResult
    private func publish(_ buffer: Buffer) -> Bool {
        guard let document = buffer.document else { return false }
        let text = buffer.storage.string
        guard !buffer.sync.matches(text) else { return false }
        buffer.sync.editorDidWrite(text)  // before the write: the `text` publisher fires synchronously and must see it as ours
        document.text = text
        document.noteUserEdit()
        return true
    }

    /// Model -> storage, for a change that did not come from this storage.
    private func modelDidChange(_ buffer: Buffer, to modelText: String) {
        guard let document = buffer.document, let textView,
              let text = buffer.sync.reloadText(document: document, modelText: modelText) else { return }
        if buffer === shown {
            // Keeps the first visible source line, not the pixel offset: a change above the viewport changes heights. The
            // selection is remapped by `reloadText` (clamped when its text is gone).
            let line = textView.topVisibleLine
            textView.reloadText(text)
            textView.scroll(toLine: line)
        } else {
            textView.replaceContents(of: buffer.storage, with: text)
        }
    }

    // MARK: Going away

    /// The window is closing. Undo steps aimed at these storages go with them: nothing would keep the storages in step with
    /// the model any more, and replaying a step on a stale one would edit text that is not there.
    public func close() {
        for buffer in buffers.values {
            buffer.document?.undoManager?.removeAllActions(withTarget: buffer.storage)
            buffer.stopObserving()
        }
        buffers = [:]
        shown = nil
    }
}
