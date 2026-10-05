import SwiftUI

/// `@AppStorage` keys of the two optional bits of window chrome (View menu, Settings ▸ Editor ▸ Layout). Both default to
/// hidden, like the original MacDown's bare window.
enum WindowChromeKey {
    static let statusBar = "window.showStatusBar"
    static let divider = "window.showDivider"
}

/// Editor and preview side by side (or either alone), laid out by `SplitLayout`. Does not observe the document itself,
/// so typing re-renders only `PreviewPane` (which does), not this view or the editor.
///
/// Both panes always stay in the view tree: hiding one only fades it out at full width. Removing the editor would drop
/// its window's text storages (the undo steps aimed at them would have to move out) and selection; removing the preview would reload the web page; and an editor squeezed to zero width
/// makes TextKit 2 lay a large document out one character per line.
struct DocumentView: View {
    let model: WindowModel
    /// The active tab's document. The view lives on when this changes: the editor and preview only swap their text.
    let document: MarkdownDocument
    /// Follows a rename / move: the workspace hands over the tab's current URL.
    let fileURL: URL
    let preview: PreviewModel
    let scrollSync: ScrollSyncController
    let editor: EditorHandle
    let status: EditorStatus

    @AppStorage(ScrollSyncPreferences.syncKey) private var syncScrolling = true
    @AppStorage(ScrollSyncPreferences.followCaretKey) private var previewFollowsCaret = false
    @AppStorage(EditorSettingKey.editorOnRight) private var editorOnRight = false
    @AppStorage(WindowChromeKey.statusBar) private var showsStatusBar = false
    @AppStorage(WindowChromeKey.divider) private var showsDivider = false
    @AppStorage(ToolbarStyle.key) private var toolbarStyle = ToolbarStyle.default

    private var layout: SplitLayout { model.layout }

    private func setLayout(_ new: SplitLayout) {
        model.userSetLayout(new)
        if !new.showsEditor { editor.resignFocus() }  // never type into an invisible editor
    }

    var body: some View {
        let layout = layout
        let tabURL = fileURL
        let fileURL: URL? = tabURL.isUntitled ? nil : tabURL  // an untitled document has no folder to resolve images or includes in
        let flavor = AppExtensions.flavor(for: fileURL)  // observable: re-evaluated when an extension is switched
        let actions = WindowActions(
            editor: editor, layout: layout, setLayout: setLayout,
            copyHTML: { [document, fileURL] in Task { await CopyHTML.copy(document.text, fileURL: fileURL) } },
            exportHTML: { [document, fileURL] in Task { await DocumentExport.html(of: document.text, fileURL: fileURL) } },
            exportPDF: { [document, fileURL] in Task { await DocumentExport.pdf(of: document.text, fileURL: fileURL) } },
            printDocument: { [document, fileURL] in Task { await DocumentExport.print(document.text, fileURL: fileURL) } },
            showOutline: { model.showOutline() }
        )
        GeometryReader { geometry in
            let total = geometry.size.width, height = geometry.size.height
            let editorWidth = layout.editorWidth(total: total)
            // Editor on the right swaps the two columns (only matters when both show); the divider follows.
            let swapped = editorOnRight && layout.mode == .both
            let dividerX = swapped ? total - editorWidth : editorWidth
            ZStack(alignment: .topLeading) {
                EditorPane(
                    document: document, scrollSync: scrollSync, editor: editor, status: status, flavor: flavor,
                    onUserEdit: { [model] document in if let url = document.tabURL { model.controller.pin(url) } }
                )
                    .frame(width: layout.mode == .both ? editorWidth : total, height: height)
                    .offset(x: swapped ? total - editorWidth : 0)
                    .visible(layout.showsEditor)
                PreviewPane(document: document, documentURL: fileURL, model: preview, flavor: flavor)
                    .frame(width: layout.mode == .both ? total - editorWidth : total, height: height)
                    .offset(x: layout.mode == .both && !swapped ? editorWidth : 0)
                    .visible(layout.showsPreview)
                if layout.mode == .both {
                    divider(at: dividerX, total: total, height: height, editorOnRight: swapped)
                }
            }
            .coordinateSpace(.named("split"))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsStatusBar {
                StatusBar(document: document, preview: preview, status: status, renderMode: flavor?.badge?.title ?? "Markdown", renderModeHelp: flavor?.badge?.help)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar { DocumentToolbar(actions: actions, style: toolbarStyle) }
        .focusedSceneValue(\.windowActions, actions)
        .task { await IsolatedTestHooks.toggleTaskThroughPage(model: model, preview: preview, editor: editor, document: document) }
        .task { await IsolatedTestHooks.tabSwitchUndo(model: model, editor: editor) }
        .task { await IsolatedTestHooks.previewEditing(model: model, preview: preview, editor: editor, document: document) }
        .onAppear {
            scrollSync.attach(preview: preview)
            preview.onToggleTask = { [editor] task, checked, text in editor.toggleTask(task, checked: checked, renderedText: text) }
            // Preview editing and two-way selection (PLAN M2): edits typed in the preview go into the editor, each pane shows the other's
            // selection. Weak both ways: the preview model and the editor handle refer to each other through these.
            preview.onPreviewEdit = { [weak editor] edit, expected in editor?.applyPreviewEdit(edit, expectedText: expected) }
            preview.onPreviewSelection = { [weak editor] range, text in editor?.showPeerHighlight(range, text: text) }
            // Selection and text read together from the text view when the preview looks (the model may not have the text yet, after an
            // undo or a command).
            editor.onSelectionChange = { [weak preview, weak editor] _ in
                preview?.showEditorSelection { [weak editor] in editor?.textView.map { ($0.selectedRange(), $0.string) } }
            }
        }
        .onChange(of: syncScrolling, initial: true) { _, on in scrollSync.isEnabled = on }
        .onChange(of: previewFollowsCaret, initial: true) { _, on in scrollSync.followsCaret = on }
    }

    /// One-point separator (drawn only with "show divider" on) with a wider invisible grab area (always there).
    private func divider(at x: Double, total: Double, height: Double, editorOnRight: Bool) -> some View {
        Rectangle().fill(showsDivider ? AnyShapeStyle(.separator) : AnyShapeStyle(.clear)).frame(width: 1, height: height)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split")).onChanged { drag in
                            guard total > 0 else { return }
                            let fraction = editorOnRight ? 1 - drag.location.x / total : drag.location.x / total
                            model.editorFraction = min(max(fraction, SplitLayout.minFraction), SplitLayout.maxFraction)
                        }
                    )
            }
            .offset(x: x - 0.5)
    }
}

private extension View {
    /// Shown, or invisible and inert but still laid out. A hidden pane goes behind the visible one.
    func visible(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown).zIndex(shown ? 1 : 0)
    }
}
