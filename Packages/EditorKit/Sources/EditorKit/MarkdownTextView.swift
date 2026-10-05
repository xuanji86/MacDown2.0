import AppKit
import ExtensionAPI

/// Scroll view that stays in the overlay style even with System Settings ▸ "Show scroll bars: Always" (and when the user
/// flips that setting later; AppKit re-applies the system style on its own, so only the getter/setter can pin it). The
/// legacy style reserves a ~15 pt track that shows as a pale strip between the dark editor and the preview; the original
/// MacDown has none. The scroller still appears while scrolling.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// Clip view that can let the document scroll up by half a window more than its height ("scroll past the end"): the last
/// line can then sit about mid-window. Only the scrollable range changes; the text view, its container and its layout are
/// untouched (no fake content height, no TextKit work). The extra space shows the scroll view's background.
final class EditorClipView: NSClipView {
    var scrollsPastEnd = false {
        didSet {
            guard scrollsPastEnd != oldValue else { return }
            scroll(to: constrainBoundsRect(bounds).origin)  // switched off while scrolled into the extra space: come back
            enclosingScrollView?.reflectScrolledClipView(self)
        }
    }

    /// How far beyond the document the view may scroll.
    var extraScrollHeight: CGFloat { scrollsPastEnd ? (bounds.height / 2).rounded(.down) : 0 }

    /// A click below the document (in the extra space) is a click below the last line: the text view puts the caret at the end
    /// (and tracks the drag), as it would for a click in its own empty area.
    override func mouseDown(with event: NSEvent) {
        if let document = documentView, isInExtraSpace(convert(event.locationInWindow, from: nil)) {
            document.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    func isInExtraSpace(_ point: NSPoint) -> Bool {
        guard scrollsPastEnd, let document = documentView else { return false }
        return point.y > document.frame.maxY
    }

    override var documentRect: NSRect {
        var rect = super.documentRect
        rect.size.height += extraScrollHeight
        return rect
    }
}

/// `visibleLines` are whole consecutive lines, `firstLine` the 0-based index of the first (`DocumentFlavor.editorDecorations`).
public typealias DecorationProvider = @MainActor (_ visibleLines: [Substring], _ firstLine: Int) -> [DecorationSpan]

/// Plain-text Markdown editor view, TextKit 2. Never touch the TextKit 1 layout-manager accessor here or anywhere in
/// this package: it silently downgrades the view (guarded by `Scripts/check-module-boundaries.sh`).
@MainActor
public final class MarkdownTextView: NSTextView {
    public var theme: EditorTheme = .default {
        didSet { applyTheme() }
    }

    /// Called when the visible region scrolls or resizes, with `topVisibleLine`. Only computed while set.
    public var onVisibleLineChange: ((Double) -> Void)?

    /// Auto-pairing, list continuation, Tab behaviour and the settings the formatting commands follow.
    public var behavior = EditorBehavior()

    /// A document flavor's overlay on the highlighting (Quarto cells, `:::`, shortcodes); nil = Markdown only.
    public var decorations: DecorationProvider? {
        didSet { highlighter?.setDecorator(decorations) }
    }

    /// Line numbers, line spacing, column width, invisibles, smart Home: set with `apply(settings:)`.
    public private(set) var viewSettings = EditorViewSettings()

    private(set) var highlighter: MarkdownHighlighter?
    private(set) var gutter: LineNumberRulerView?
    /// Side inset of the text, kept apart from `textContainerInset` so a width limit can replace it and give it back.
    private static let baseInset = NSSize(width: 15, height: 30)  // the original MacDown's
    /// Set while our own edits go through `insertText`, so the typing assistant does not re-interpret them.
    private var isApplyingEdit = false

    /// A scroll view hosting a TextKit 2 `MarkdownTextView`, configured like `NSTextView.scrollableTextView()`.
    public static func makeScrollView(theme: EditorTheme = .default) -> (scrollView: NSScrollView, textView: MarkdownTextView) {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        assert(textView.textLayoutManager != nil, "editor must be backed by TextKit 2")
        let scrollView = OverlayScrollView()
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.contentView = EditorClipView()  // before the document view: setting a content view drops the old one's

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = baseInset
        // Source text: no typographic rewriting unless the user switched it on (`EditorViewSettings`).
        textView.applySubstitutions(textView.viewSettings)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.theme = theme  // before the highlighter exists: only sets font and colours
        textView.installHighlighter()
        textView.observeScrolling()
        textView.attachGutter()
        textView.observeStorage()
        textView.textLayoutManager?.delegate = textView
        return (scrollView, textView)
    }

    /// Observers of the text storage the view shows; they follow it when `attach(storage:)` swaps it.
    private var storageObservers: [NSObjectProtocol] = []

    private func observeStorage() {
        let center = NotificationCenter.default
        storageObservers.forEach(center.removeObserver)
        storageObservers = []
        guard let storage = textStorage else { return }
        // Undo and redo change the text without telling the delegate: NSTextView only sends `textDidChange` for typing and for an
        // explicit `didChangeText()` (observed on macOS 26/27 with TextKit 2). The model that mirrors the text, the preview and
        // the file that gets saved would keep what the user just undid. So a character edit that happens while the undo manager
        // is undoing or redoing is announced like any other.
        storageObservers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gutter?.textDidChange()
                if let manager = self.undoManager, manager.isUndoing || manager.isRedoing { self.didChangeText() }
            }
        })
    }

    private func attachGutter() {
        guard let scrollView = enclosingScrollView else { return }
        let ruler = LineNumberRulerView(scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        usesRuler = false  // the paragraph ruler (tab stops, indents) is not ours and may reach for the TextKit 1 layout
        ruler.clientView = self
        gutter = ruler
    }

    isolated deinit {
        storageObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Settings

    /// Make the view follow `settings`. Cheap when nothing changed, so the app can call it on every settings update.
    public func apply(settings: EditorViewSettings) {
        let new = settings.clamped
        let old = viewSettings
        guard new != old else { return }
        viewSettings = new
        if new.lineSpacing != old.lineSpacing { applyTheme() }
        if new.limitsWidth != old.limitsWidth || new.maxWidth != old.maxWidth { updateInsets() }
        if new.showsLineNumbers != old.showsLineNumbers {
            gutter?.updateThickness()
            enclosingScrollView?.rulersVisible = new.showsLineNumbers
            updateInsets()
        }
        if new.showsInvisibles != old.showsInvisibles { needsDisplay = true }
        if new.scrollsPastEnd != old.scrollsPastEnd { (enclosingScrollView?.contentView as? EditorClipView)?.scrollsPastEnd = new.scrollsPastEnd }
        applySubstitutions(new, replacing: old)
    }

    /// The system's automatic text substitutions follow the settings, one switch each. Only what changed is written (`old` nil =
    /// everything), so a toggle made in the Edit > Substitutions menu survives an unrelated setting change.
    private func applySubstitutions(_ new: EditorViewSettings, replacing old: EditorViewSettings? = nil) {
        if new.smartQuotes != old?.smartQuotes { isAutomaticQuoteSubstitutionEnabled = new.smartQuotes }
        if new.smartDashes != old?.smartDashes { isAutomaticDashSubstitutionEnabled = new.smartDashes }
        if new.textReplacement != old?.textReplacement { isAutomaticTextReplacementEnabled = new.textReplacement }
        if new.spellingCorrection != old?.spellingCorrection { isAutomaticSpellingCorrectionEnabled = new.spellingCorrection }
        if new.smartInsertDelete != old?.smartInsertDelete { smartInsertDeleteEnabled = new.smartInsertDelete }
    }

    /// Text column: the base inset, or whatever centres a `maxWidth` column. Called when the width or the setting changes.
    private func updateInsets() {
        let inset = EditorViewSettings.horizontalInset(
            viewWidth: bounds.width, maxWidth: viewSettings.limitsWidth ? viewSettings.maxWidth : nil, minimum: Self.baseInset.width)
        let new = NSSize(width: inset, height: Self.baseInset.height)
        if textContainerInset != new { textContainerInset = new }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, viewSettings.limitsWidth { updateInsets() }
    }

    private func installHighlighter() {
        do {
            highlighter = try MarkdownHighlighter(textView: self, theme: styledTheme)
            if decorations != nil { highlighter?.setDecorator(decorations) }  // a storage swap installs a new highlighter
        } catch {
            // The grammar ships in the binary; failing here is a build problem, but the editor must stay usable plain.
            assertionFailure("highlighter unavailable: \(error)")
        }
    }

    private func observeScrolling() {
        guard let scrollView = enclosingScrollView else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(visibleContentChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(visibleContentChanged), name: NSView.frameDidChangeNotification, object: scrollView)
    }

    /// The theme plus the view-level settings that end up in text attributes.
    private var styledTheme: EditorTheme {
        var styled = theme
        styled.lineSpacing = viewSettings.lineSpacing
        return styled
    }

    private func applyTheme() {
        let theme = styledTheme
        backgroundColor = theme.background
        insertionPointColor = theme.caret
        selectedTextAttributes = [.backgroundColor: theme.selection]
        applyStorageTheme()
        gutter?.updateThickness()
        gutter?.needsDisplay = true
        enclosingScrollView?.backgroundColor = theme.background
        // Chrome (scroll bars, find bar) follows the theme, not the system.
        appearance = theme.chromeAppearance
        enclosingScrollView?.appearance = appearance
        highlighter?.setTheme(theme)  // repaints later while marked text is in flight
    }

    /// Set when a theme change had to leave the text storage alone because an input method was composing.
    private var themeNeedsStorage = false

    /// The part of a theme that rewrites attributes of the text itself (font, line spacing). `font` is applied to the whole
    /// storage, marked range included, which ends an input-method composition: while text is marked it waits
    /// (`compositionDidEnd`).
    private func applyStorageTheme() {
        guard !hasMarkedText() else {
            themeNeedsStorage = true
            return
        }
        themeNeedsStorage = false
        let theme = styledTheme
        font = theme.font
        typingAttributes = theme.baseAttributes
        defaultParagraphStyle = theme.paragraphStyle
        // The highlighter styles the visible chunks; the rest must not keep the old line spacing meanwhile (scroll extent).
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: storage.length))
            if let layout = textLayoutManager { layout.invalidateLayout(for: layout.documentRange) }
        }
    }

    /// The marked range was committed or discarded: what waited for it (the theme's text attributes, the repaint) happens now.
    private func compositionDidEnd() {
        if themeNeedsStorage {
            applyStorageTheme()
            gutter?.updateThickness()
            gutter?.needsDisplay = true
        }
        highlighter?.compositionDidEnd()
    }

    @objc private func visibleContentChanged() {
        if viewSettings.showsLineNumbers { gutter?.needsDisplay = true }
        highlighter?.visibleContentDidChange()
        onVisibleLineChange?(topVisibleLine)
    }

    // MARK: IME

    // While text is marked (Chinese/Japanese composition) no attributes are written: restyling would end the
    // composition. The highlighter repaints once it ends.
    public override func unmarkText() {
        super.unmarkText()
        compositionDidEnd()
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if !isApplyingEdit, replacementRange.location == NSNotFound, !hasMarkedText(), let typed = string as? String,
           let storage = textStorage,
           let edit = EditingAssistant.typed(typed, in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        compositionDidEnd()
    }

    // MARK: Editing assistance (PLAN 4.3.4). All of it steps aside while an input method has marked text.

    public override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.newline(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    public override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.tab(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertTab(sender)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.backtab(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let storage = textStorage,
           let edit = EditingAssistant.backspace(in: storage.mutableString, selection: selectedRange(), behavior: behavior) {
            applyEdit(edit)
        } else {
            super.deleteBackward(sender)
        }
    }

    /// Run a menu/toolbar formatting command on the current selection (undoable as one step). No-op while an input
    /// method is composing or the view is read-only.
    public func perform(_ command: MarkdownCommand, pasteboard: NSPasteboard = .general) {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return }
        let clipboard = pasteboard.string(forType: .string)
        guard let edit = command.edit(in: storage.mutableString, selection: selectedRange(), clipboard: clipboard, behavior: behavior) else { return }
        applyEdit(edit)
    }

    /// Replaces `range` with `string` for something outside the editor (the preview ticked a task checkbox) as ONE undo step
    /// called `actionName`, kept apart from any typing before or after it. The text storage is edited in place, so the
    /// highlighter restyles only what the edit touches and the delegate hears `textDidChange` as for typing. The selection
    /// is put back exactly as it was (callers swap equal lengths, so it still points at the same text). Returns false, with
    /// nothing changed, while an input method has marked text or when `range` is not inside the text.
    @discardableResult
    public func replaceUndoably(_ range: NSRange, with string: String, actionName: String) -> Bool {
        guard isEditable, !hasMarkedText(), let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        let selection = selectedRanges
        breakUndoCoalescing()
        let manager = undoManager
        manager?.beginUndoGrouping()
        defer {
            manager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        guard shouldChangeText(in: range, replacementString: string) else { return false }
        storage.replaceCharacters(in: range, with: string)
        didChangeText()
        manager?.setActionName(actionName)
        if selectedRanges != selection { selectedRanges = selection }
        return true
    }

    /// Every programmatic change goes through `insertText`, i.e. `shouldChangeText` / undo registration / the delegate's
    /// `textDidChange`, exactly like typing. A pure caret move (stepping over a closer) touches no text.
    func applyEdit(_ edit: TextEdit) {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            insertText(edit.replacement, replacementRange: edit.range)
        }
        setSelectedRange(edit.selection)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if viewSettings.showsLineNumbers { gutter?.needsDisplay = true }  // the current line's number is emphasised
    }

    // MARK: Paste (PLAN parity: paste image, smart URL)

    /// The file of the document this view shows, asked at paste time (the view is reused across tabs). nil closure = image
    /// paste is off and an image on the pasteboard does what NSTextView always did (nothing); a closure returning nil = the
    /// document has never been saved, so there is no folder to put the image in (`onPasteImageProblem(.needsSavedDocument)`).
    public var documentURL: (@MainActor () -> URL?)?
    /// Asked before an image file is read and before `images/` is created; false = refuse (isolated launches stay in their root).
    public var pastePermits: (@MainActor (URL) -> Bool)?
    /// An image paste that could not happen. Nothing was written for the part that failed; the app tells the user.
    public var onPasteImageProblem: (@MainActor (PasteImageProblem) -> Void)?
    /// What Paste reads and Edit > Paste validates against; tests give it a private pasteboard.
    var pasteSource: NSPasteboard = .general

    public enum PasteImageProblem {
        case needsSavedDocument
        case failed(PasteImageError)
    }

    public override func paste(_ sender: Any?) {
        if isEditable, !hasMarkedText(), pasteIfSmart(from: pasteSource) { return }
        super.paste(sender)
    }

    /// NSTextView enables Paste only for the types it can read, and a screenshot or "Copy Image" has none of them: with image
    /// support on, an image on the pasteboard enables it too (`paste` then saves it, or asks to save the document first).
    private var canPasteImage: Bool { isEditable && documentURL != nil && PasteImage.offersImage(on: pasteSource) }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), canPasteImage { return true }
        return super.validateUserInterfaceItem(item)
    }

    public override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), canPasteImage { return true }
        return super.validateMenuItem(item)
    }

    /// An image on the pasteboard becomes files next to the document plus `![image](images/…)`; a URL over a selection becomes a
    /// link. True when handled here. The text insertion is one undo step of its own (`breakUndoCoalescing`), and undoing it
    /// leaves the image files in place: they may be referenced by now, and deleting user files on ⌘Z is the worse surprise.
    public func pasteIfSmart(from pasteboard: NSPasteboard) -> Bool {
        guard let storage = textStorage else { return false }
        guard documentURL != nil, let candidates = PasteImage.candidates(on: pasteboard) else { return linkPaste(pasteboard, storage) }
        // Before anything is read or decoded: an unsaved document has no folder to put the image in.
        guard let folder = documentURL?()?.deletingLastPathComponent() else {
            onPasteImageProblem?(.needsSavedDocument)
            return true
        }
        let permits = pastePermits ?? { _ in true }
        let images: [PastedImage]
        do {
            // nil: image files that cannot be used; the normal paste (their names) runs.
            guard let loaded = try PasteImage.load(candidates, permits: permits) else { return linkPaste(pasteboard, storage) }
            images = loaded
        } catch {
            onPasteImageProblem?(.failed(error as? PasteImageError ?? .io(error)))
            return true
        }
        var paths: [String] = []
        var problem: PasteImageError?
        for image in images {
            do { paths.append(try PasteImage.write(image, besideDocumentIn: folder, permits: permits)) } catch {
                problem = error as? PasteImageError ?? .io(error)
                break
            }
        }
        if !paths.isEmpty { applyAsOwnUndoStep(PasteImage.edit(forPaths: paths, replacing: selectedRange())) }
        if let problem { onPasteImageProblem?(.failed(problem)) }
        return true
    }

    private func linkPaste(_ pasteboard: NSPasteboard, _ storage: NSTextStorage) -> Bool {
        guard pasteboard.availableType(from: [.string]) != nil, let clipboard = pasteboard.string(forType: .string),
              let edit = SmartPaste.linkEdit(clipboard: clipboard, selection: selectedRange(), in: storage.mutableString) else { return false }
        applyAsOwnUndoStep(edit)
        return true
    }

    /// Kept apart from the typing before and after it, so one ⌘Z takes back the paste and nothing else.
    private func applyAsOwnUndoStep(_ edit: TextEdit) {
        breakUndoCoalescing()
        applyEdit(edit)
        breakUndoCoalescing()
    }

    // MARK: Smart Home

    public override func moveToBeginningOfLine(_ sender: Any?) { smartHome(sender) { super.moveToBeginningOfLine(sender) } }
    public override func moveToLeftEndOfLine(_ sender: Any?) { smartHome(sender) { super.moveToLeftEndOfLine(sender) } }

    /// ⌘←: the system move first. When it lands on the real start of the line (the caret was on the line's first visual
    /// row, so not on a wrapped continuation, which keeps the system behaviour), the first stop is the first non-blank
    /// character instead, and the next press goes on to the line start.
    private func smartHome(_ sender: Any?, system: () -> Void) {
        let before = selectedRange()
        guard viewSettings.smartHome, before.length == 0, !hasMarkedText(), let text = textStorage?.mutableString else { return system() }
        system()
        let after = selectedRange()
        guard after.length == 0, after.location == SmartHome.lineStart(in: text, caret: before.location) else { return }
        let target = SmartHome.target(in: text, caret: before.location)
        if target != after.location {
            setSelectedRange(NSRange(location: target, length: 0))
            scrollRangeToVisible(selectedRange())
        }
    }

    // MARK: Loading text from outside

    /// Replace the whole text because the model changed behind the editor's back. Keeps the selection where it makes
    /// sense and the scroll position; registers no undo and leaves the undo history alone (a revert clears it in the document,
    /// a peer editor's edit must not).
    public func reloadText(_ text: String) {
        endComposition()
        let old = string
        guard old != text else { return }
        let selection = selectedRanges.map(\.rangeValue)
        let origin = enclosingScrollView?.contentView.bounds.origin
        string = text
        selectedRanges = selection.map { NSValue(range: ExternalTextSync.remap($0, from: old, to: text)) }
        if let origin, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Keeps the marked text as typed (what AppKit does when focus leaves the view) and announces the change like any other
    /// edit, so the model and the undo history follow. Call before something swaps the view's text under a composition.
    public func commitComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
        didChangeText()
    }

    private func endComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    // MARK: Several texts, one view

    /// A storage holding `text`, in the view's current theme, to show with `attach(storage:)` (or to keep for later).
    public func makeStorage(text: String) -> NSTextStorage {
        NSTextStorage(string: text, attributes: styledTheme.baseAttributes)
    }

    /// Replaces everything in a storage that is not on screen (one made by `makeStorage`) without touching its undo history.
    public func replaceContents(of storage: NSTextStorage, with text: String) {
        storage.setAttributedString(NSAttributedString(string: text, attributes: styledTheme.baseAttributes))
    }

    /// Shows `storage` instead of the current one: its text, selection reset to the start, and highlighting. The view keeps
    /// no reference to the storage it left, so one that is kept (a tab that is not in front) can still be edited and undone
    /// while off screen. That is the point: NSTextView records an undo step against the storage the edit happened in, and an
    /// undo manager cannot be told to retarget one, so a single storage shared by every document would let one document's
    /// undo change another's text. Give each document its own storage and swap it in.
    public func attach(storage: NSTextStorage) {
        guard let content = textContentStorage, content.textStorage !== storage else { return }
        endComposition()
        breakUndoCoalescing()
        highlighter?.stop()  // it must not look at the storage it painted any more: that one may be edited off screen
        highlighter = nil
        content.textStorage = storage
        setSelectedRange(NSRange(location: 0, length: 0))
        observeStorage()
        applyStorageTheme()
        installHighlighter()
        gutter?.updateThickness()
        gutter?.needsDisplay = true
        needsDisplay = true
    }

    // MARK: Scroll sync (lines are 0-based source lines, fractional = progress through the line)

    /// First visible source line plus how far its layout fragment is scrolled past. Source lines, not wrapped rows.
    public var topVisibleLine: Double {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return 0 }
        let y = max(0, visibleRect.minY - textContainerOrigin.y)
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let progress = frame.height > 0 ? min(max((y - frame.minY) / frame.height, 0), 0.999) : 0
        return Double(lineIndex(atOffset: offset)) + progress
    }

    /// 0-based source line holding the insertion point (selection start).
    public var caretLine: Int { lineIndex(atOffset: selectedRange().location) }

    /// 0-based column of the insertion point in characters (grapheme clusters, so CJK and emoji count as one).
    public var caretColumn: Int {
        let text = (textStorage?.string ?? "") as NSString
        let location = min(selectedRange().location, text.length)
        // Lines end at "\n" only, like `lineIndex(atOffset:)`.
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location))
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        return text.substring(with: NSRange(location: lineStart, length: location - lineStart)).count
    }

    /// Puts the caret at the start of `line` (0-based) and scrolls it to the top of the visible area.
    public func goTo(line: Int) {
        setSelectedRange(NSRange(location: offsetOfLine(line), length: 0))
        scroll(toLine: Double(line))
    }

    /// A search result: selects `columns` (UTF-16 offsets within `line`, 0-based; clamped to the line, so a file that changed
    /// since the search cannot select past it), shows it a few lines below the top and flashes it like Find does. Without
    /// `columns` the caret goes to the start of the line.
    public func reveal(line: Int, columns: Range<Int>?) {
        let text = (textStorage?.string ?? "") as NSString
        let start = offsetOfLine(line)
        let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
        let end = newline.location == NSNotFound ? text.length : newline.location
        var range = NSRange(location: start, length: 0)
        if let columns {
            let lower = min(start + columns.lowerBound, end), upper = min(start + columns.upperBound, end)
            range = NSRange(location: lower, length: upper - lower)
        }
        setSelectedRange(range)
        scroll(toLine: Double(max(0, line - 3)))
        scrollRangeToVisible(range)
        if range.length > 0 { showFindIndicator(for: range) }
    }

    /// Scroll so that `line` is at the top of the visible area (no animation).
    public func scroll(toLine line: Double) {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let scrollView = enclosingScrollView else { return }
        let whole = max(0, Int(line.rounded(.down)))
        let progress = min(max(line - Double(whole), 0), 0.999)
        let offset = offsetOfLine(whole)
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return }
        // A fragment that was never laid out reports a zero frame; lay out just the target, then let the view adopt the
        // grown content height (otherwise the clip view cannot scroll that far).
        if let end = content.location(location, offsetBy: 1), let target = NSTextRange(location: location, end: end) {
            layout.ensureLayout(for: target)
        }
        layoutSubtreeIfNeeded()
        guard let fragment = layout.textLayoutFragment(for: location) else { return }
        let frame = fragment.layoutFragmentFrame
        let clip = scrollView.contentView
        let target = frame.minY + progress * frame.height + textContainerOrigin.y
        // The clip view knows the limits (document, content insets, scroll past end).
        let wanted = NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: max(target, 0)), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // lazy: both scan from the start per call (memchr-speed, <1 ms at 1 MB); cache a line-start table if scroll sync shows up in a profile
    func lineIndex(atOffset offset: Int) -> Int {
        let text = textStorage?.mutableString ?? NSMutableString()
        var count = 0, i = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        let end = min(offset, text.length)
        while i < end {
            let n = min(buffer.count, end - i)
            text.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 0x0A { count += 1 }
            i += n
        }
        return count
    }

    func offsetOfLine(_ line: Int) -> Int {
        guard line > 0 else { return 0 }
        let text = textStorage?.mutableString ?? NSMutableString()
        var seen = 0, i = 0, lastStart = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        while i < text.length {
            let n = min(buffer.count, text.length - i)
            text.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 0x0A {
                seen += 1
                lastStart = i + k + 1
                if seen == line { return lastStart }
            }
            i += n
        }
        return lastStart  // fewer lines than asked for: the last line
    }
}

extension NSTextView {
    /// UTF-16 range of the characters whose layout fragments intersect the visible rect (TextKit 2; nil when there
    /// is no layout yet, e.g. no window).
    var visibleCharacterRange: NSRange? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let rect = visibleRect
        guard !rect.isEmpty else { return nil }
        let top = rect.minY - textContainerOrigin.y, bottom = rect.maxY - textContainerOrigin.y
        let length = textStorage?.length ?? 0
        func offset(of location: NSTextLocation) -> Int { content.offset(from: content.documentRange.location, to: location) }
        let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top))).map { offset(of: $0.rangeInElement.location) } ?? 0
        let end = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bottom))).map { offset(of: $0.rangeInElement.endLocation) } ?? length
        return NSRange(location: min(start, length), length: max(0, min(end, length) - min(start, length)))
    }
}

// MARK: Layout fragments (invisible characters)

extension MarkdownTextView: @MainActor NSTextLayoutManagerDelegate {
    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = InvisiblesLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.marks = { [weak self] in
            guard let self else { return (false, .clear, .systemFont(ofSize: 12)) }
            return (viewSettings.showsInvisibles, theme.lineNumber, theme.font)
        }
        return fragment
    }
}
