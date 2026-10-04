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
    /// "Markdown", or the flavor's badge title ("Quarto · Approximate Preview") with its tooltip.
    var renderMode = "Markdown"
    var renderModeHelp: String?
    @AppStorage("statusBar.countMode") private var mode = CountMode.words

    var body: some View {
        let selection = status.selection
        let stats = selection ?? preview.metadata?.stats
        HStack(spacing: 12) {
            Text("Ln \(status.line + 1), Col \(status.column + 1)")
            Button { mode = mode.next } label: {
                Text(stats.map { mode.label($0.count(mode), selected: selection != nil) } ?? "—")
            }
            .buttonStyle(.plain)
            .help("Click to change what is counted")
            if document.editedFlag.missing {
                Label("The file was deleted or moved; saving will recreate it", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
        Menu {
            EncodingMenuItems(document: document)
        } label: {
            Text(document.format.label)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(encodingHelp)
    }

    private var encodingHelp: LocalizedStringKey {
        document.canReopenWithEncoding
            ? "File encoding and line endings. Click to reopen with another encoding"
            : "File encoding and line endings. Save the file to reopen it with another encoding"
    }
}

/// "Reopen with encoding" and "convert to UTF-8": the status bar's encoding menu, and File ▸ Encoding for when the bar is hidden.
struct EncodingMenuItems: View {
    let document: MarkdownDocument

    var body: some View {
        let format = document.format
        Section("Reopen with Encoding") {
            ForEach(TextEncoding.allCases, id: \.self) { encoding in
                Toggle(encoding.displayName, isOn: Binding(get: { format.encoding == encoding }, set: { _ in reopen(as: encoding) }))
            }
        }
        .disabled(!document.canReopenWithEncoding)
        Divider()
        Button("Convert to UTF-8 and Save") { document.convertToUTF8() }
            .disabled(format.encoding == .utf8)
    }

    private func reopen(as encoding: TextEncoding) {
        guard encoding != document.format.encoding else { return }
        do { try document.reopen(as: encoding) } catch { document.presentError(error) }
    }
}

extension MarkdownDocument {
    /// Re-reading discards unsaved edits, so it waits until the document is saved; an unsaved new document has no file to re-read.
    var canReopenWithEncoding: Bool { fileURL != nil && !editedFlag.value }
}

private extension CountMode {
    /// "1,234 words", or "12 words selected" when it counts the selection.
    func label(_ count: Int, selected: Bool) -> String {
        switch (self, selected) {
        case (.words, false): String(localized: "\(count) words")
        case (.words, true): String(localized: "\(count) words selected")
        case (.characters, false): String(localized: "\(count) characters")
        case (.characters, true): String(localized: "\(count) characters selected")
        case (.charactersNoSpaces, false): String(localized: "\(count) characters (no spaces)")
        case (.charactersNoSpaces, true): String(localized: "\(count) characters selected (no spaces)")
        }
    }
}
