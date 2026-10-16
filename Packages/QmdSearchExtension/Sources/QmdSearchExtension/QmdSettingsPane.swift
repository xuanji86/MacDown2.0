import SwiftUI

/// Settings ▸ Extensions ▸ qmd Search (PLAN 4.8). Exists only while the extension is on; unfolding it is what looks for qmd.
struct QmdSettingsPane: View {
    @Bindable var settings: QmdSettings
    let engine: QmdEngine

    @State private var tool: QmdTool?
    @State private var blockedBy: [String] = []
    @State private var embedding = false
    @State private var embedResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(statusText).multilineTextAlignment(.trailing).textSelection(.enabled)
            } label: {
                Text("qmd", bundle: .module)
            }
            if needsInstall { installHint }
            HStack {
                TextField(text: $settings.manualPath, prompt: Text("Found on your login shell’s PATH", bundle: .module)) {
                    Text("Path to qmd", bundle: .module)
                }
                .onSubmit { Task { await check(force: true) } }
                Button { Task { await check(force: true) } } label: { Text("Check Again", bundle: .module) }
            }
            Toggle(isOn: $settings.semantic) { Text("Semantic search", bundle: .module) }
            caption(Text("Return in the search field, or the sparkles button, asks qmd for documents with a similar meaning. The first semantic search downloads about 2 GB of models into qmd’s cache and each one takes seconds.", bundle: .module))
            if settings.semantic {
                Toggle(isOn: $settings.rerank) { Text("Rerank results (another model, slower)", bundle: .module) }
                Toggle(isOn: $settings.autoEmbed) { Text("Update embeddings while the Mac is idle", bundle: .module) }
                HStack {
                    Button { Task { await embedNow() } } label: { Text("Update Embeddings Now", bundle: .module) }
                        .disabled(embedding)
                    if embedding { ProgressView().controlSize(.small) }
                    if let embedResult { caption(Text(verbatim: embedResult)) }
                }
            }
            if !blockedBy.isEmpty {
                caption(Text("The index is not refreshed automatically because “qmd update” would also run the update command of: \(blockedBy.joined(separator: ", ")). Run “qmd update” in Terminal when files have changed.", bundle: .module))
            }
            caption(Text("qmd keeps one index for all your collections. A folder is added to it only after you agree, as a collection that your own qmd searches leave out; right-click the folder in the sidebar to remove it again.", bundle: .module))
            if !settings.declinedFolders.isEmpty {
                Button {
                    settings.forgetDeclined()
                    Task { await engine.resetUnavailable() }
                } label: { Text("Ask Again for Declined Folders", bundle: .module) }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .task { await check(force: false) }
    }

    private var statusText: String {
        switch tool {
        case nil: L10n.looking
        case .found(let path, let version): "\(path) · \(version)"
        case .broken(_, let message): message
        case let tool?: L10n.note(for: tool)
        }
    }

    private var needsInstall: Bool {
        switch tool {
        case .notFound?, .unsupported?: true
        default: false
        }
    }

    private var installHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(Text("Install qmd (needs Node.js 22 or later, or Bun), and Homebrew’s SQLite, which qmd’s vector extension needs:", bundle: .module))
            Text(verbatim: "npm i -g @tobilu/qmd\nbrew install sqlite")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func caption(_ text: Text) -> some View {
        text.font(.caption).foregroundStyle(.secondary)
    }

    private func check(force: Bool) async {
        if force { tool = nil }
        tool = await engine.detect(force: force)
        blockedBy = await engine.updatesBlockedBy
    }

    private func embedNow() async {
        embedding = true
        embedResult = nil
        embedResult = await engine.embed() ?? L10n.embedDone
        embedding = false
    }
}
