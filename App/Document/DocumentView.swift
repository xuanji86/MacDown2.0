import SwiftUI

/// Editor on the left, preview on the right. Does not observe the document itself, so typing re-renders only
/// `PreviewPane` (which does), not this view or the editor.
struct DocumentView: View {
    let document: MarkdownDocument
    /// nil until the document is saved; follows Save As / move because the scene hands over a fresh value.
    var fileURL: URL?

    @State private var preview = PreviewModel()
    @State private var scrollSync = ScrollSyncController()
    @AppStorage(ScrollSyncPreferences.syncKey) private var syncScrolling = true
    @AppStorage(ScrollSyncPreferences.followCaretKey) private var previewFollowsCaret = false

    var body: some View {
        HSplitView {
            EditorPane(document: document, scrollSync: scrollSync)
                .frame(minWidth: 240)
            PreviewPane(document: document, documentURL: fileURL, model: preview)
                .frame(minWidth: 240)
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { scrollSync.attach(preview: preview) }
        .onChange(of: syncScrolling, initial: true) { _, on in scrollSync.isEnabled = on }
        .onChange(of: previewFollowsCaret, initial: true) { _, on in scrollSync.followsCaret = on }
    }
}
