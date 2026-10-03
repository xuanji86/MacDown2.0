import SwiftUI

/// Editor and preview side by side (or either alone), laid out by `SplitLayout`. Does not observe the document itself,
/// so typing re-renders only `PreviewPane` (which does), not this view or the editor.
///
/// Both panes always stay in the view tree: hiding one only fades it out at full width. Removing the editor would drop
/// its undo stack and selection; removing the preview would reload the web page; and an editor squeezed to zero width
/// makes TextKit 2 lay a large document out one character per line.
struct DocumentView: View {
    let document: MarkdownDocument
    /// nil until the document is saved; follows Save As / move because the scene hands over a fresh value.
    var fileURL: URL?

    @State private var preview = PreviewModel()
    @State private var scrollSync = ScrollSyncController()
    @AppStorage(ScrollSyncPreferences.syncKey) private var syncScrolling = true
    @AppStorage(ScrollSyncPreferences.followCaretKey) private var previewFollowsCaret = false

    // Per window, restored with the window.
    @SceneStorage("split.mode") private var modeRaw = SplitLayout.Mode.both.rawValue
    @SceneStorage("split.editorFraction") private var editorFraction = 0.5
    @State private var editor = EditorHandle()
    @State private var status = EditorStatus()
    @SceneStorage("outline.shown") private var showsOutline = false

    private var layout: SplitLayout {
        SplitLayout(mode: SplitLayout.Mode(rawValue: modeRaw) ?? .both, editorFraction: editorFraction)
    }

    private func setLayout(_ new: SplitLayout) {
        modeRaw = new.mode.rawValue
        editorFraction = new.editorFraction
        if !new.showsEditor { editor.resignFocus() }  // never type into an invisible editor
    }

    var body: some View {
        let layout = layout
        let flavor = AppExtensions.flavor(for: fileURL)  // observable: re-evaluated when an extension is switched
        let actions = WindowActions(
            editor: editor, layout: layout, setLayout: setLayout,
            copyHTML: { [document, fileURL] in Task { await CopyHTML.copy(document.text, fileURL: fileURL) } },
            exportHTML: { [document, fileURL] in Task { await DocumentExport.html(of: document.text, fileURL: fileURL) } },
            exportPDF: { [document, fileURL] in Task { await DocumentExport.pdf(of: document.text, fileURL: fileURL) } },
            printDocument: { [document, fileURL] in Task { await DocumentExport.print(document.text, fileURL: fileURL) } },
            outlineShown: showsOutline, toggleOutline: { showsOutline.toggle() }
        )
        GeometryReader { geometry in
            let total = geometry.size.width, height = geometry.size.height
            let editorWidth = layout.editorWidth(total: total)
            ZStack(alignment: .topLeading) {
                EditorPane(document: document, scrollSync: scrollSync, editor: editor, status: status, flavor: flavor)
                    .frame(width: layout.mode == .both ? editorWidth : total, height: height)
                    .visible(layout.showsEditor)
                PreviewPane(document: document, documentURL: fileURL, model: preview, flavor: flavor)
                    .frame(width: layout.mode == .both ? total - editorWidth : total, height: height)
                    .offset(x: layout.mode == .both ? editorWidth : 0)
                    .visible(layout.showsPreview)
                if layout.mode == .both {
                    divider(at: editorWidth, total: total, height: height)
                }
            }
            .coordinateSpace(.named("split"))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(preview: preview, status: status, renderMode: flavor?.badge?.title ?? "Markdown", renderModeHelp: flavor?.badge?.help) }
        .inspector(isPresented: $showsOutline) {
            OutlineInspector(preview: preview, status: status, jump: jump(toLine:))
                .inspectorColumnWidth(min: 180, ideal: 240, max: 420)
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar { DocumentToolbar(actions: actions) }
        .focusedSceneValue(\.windowActions, actions)
        .onAppear { scrollSync.attach(preview: preview) }
        .onChange(of: syncScrolling, initial: true) { _, on in scrollSync.isEnabled = on }
        .onChange(of: previewFollowsCaret, initial: true) { _, on in scrollSync.followsCaret = on }
    }

    /// Outline click: the caret and both panes go to the heading's line, whatever the scroll sync settings.
    private func jump(toLine line: Int) {
        editor.goTo(line: line, focus: layout.showsEditor)
        preview.scroll(toLine: Double(line))
    }

    /// One-point separator with a wider invisible grab area.
    private func divider(at x: Double, total: Double, height: Double) -> some View {
        Rectangle().fill(.separator).frame(width: 1, height: height)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split")).onChanged { drag in
                            guard total > 0 else { return }
                            editorFraction = min(max(drag.location.x / total, SplitLayout.minFraction), SplitLayout.maxFraction)
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
