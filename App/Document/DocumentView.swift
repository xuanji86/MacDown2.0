import SwiftUI

/// Editor on the left, preview on the right. Does not observe the document itself, so typing re-renders only
/// `PreviewPane` (which does), not this view or the editor.
struct DocumentView: View {
    let document: MarkdownDocument

    var body: some View {
        HSplitView {
            EditorPane(document: document)
                .frame(minWidth: 240)
            PreviewPane(document: document)
                .frame(minWidth: 240)
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}
