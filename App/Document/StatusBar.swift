import MarkdownCore
import SwiftUI

/// Bottom-of-window glass capsule: caret position, word count (selection if there is one, else the whole document;
/// click to step through words / characters / characters without spaces) and the render mode.
struct StatusBar: View {
    let preview: PreviewModel
    let status: EditorStatus
    /// "Markdown" for now; a Quarto document will show its own flavor here.
    var renderMode = "Markdown"
    @AppStorage("statusBar.countMode") private var mode = CountMode.words

    var body: some View {
        let selection = status.selection
        let stats = selection ?? preview.metadata?.stats
        HStack(spacing: 12) {
            Text("行 \(status.line + 1)，列 \(status.column + 1)")
            Button { mode = mode.next } label: {
                Text(stats.map { "\(selection == nil ? "" : "选中 ")\($0.count(mode).formatted()) \(mode.unit)" } ?? "—")
            }
            .buttonStyle(.plain)
            .help("点击切换计数方式")
            Text(renderMode)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

private extension CountMode {
    var unit: String {
        switch self {
        case .words: "词"
        case .characters: "字符"
        case .charactersNoSpaces: "字符（不含空格）"
        }
    }
}
