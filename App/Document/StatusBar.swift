import MarkdownCore
import SwiftUI

/// Bottom-of-window glass capsule: caret position, word count (selection if there is one, else the whole document;
/// click to step through words / characters / characters without spaces), the file's encoding and line ending ("UTF-8 · LF";
/// click to reopen in another encoding or convert to UTF-8) and the render mode.
struct StatusBar: View {
    /// Not observed itself (typing must not re-render the bar); only its `format` and `editedFlag` are.
    let document: MarkdownDocument
    let preview: PreviewModel
    let status: EditorStatus
    /// "Markdown", or the flavor's badge title ("Quarto · 近似预览") with its tooltip.
    var renderMode = "Markdown"
    var renderModeHelp: String?
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
            if document.editedFlag.missing {
                Label("文件已被删除或移走,保存可重建", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            encodingMenu
            Text(renderMode).help(renderModeHelp ?? "")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var encodingMenu: some View {
        let format = document.format
        // Re-reading discards unsaved edits, so it waits until the document is saved; an unsaved new document has no file to re-read.
        let canReopen = document.fileURL != nil && !document.editedFlag.value
        return Menu {
            Section("用此编码重新打开") {
                ForEach(TextEncoding.allCases, id: \.self) { encoding in
                    Toggle(encoding.displayName, isOn: Binding(get: { format.encoding == encoding }, set: { _ in reopen(as: encoding) }))
                }
            }
            .disabled(!canReopen)
            Divider()
            Button("转为 UTF-8 保存") { document.convertToUTF8() }
                .disabled(format.encoding == .utf8)
        } label: {
            Text(format.label)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(canReopen ? "文件编码与换行符。点击可换编码重新打开" : "文件编码与换行符。保存后才能换编码重新打开")
    }

    private func reopen(as encoding: TextEncoding) {
        guard encoding != document.format.encoding else { return }
        do { try document.reopen(as: encoding) } catch { document.presentError(error) }
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
