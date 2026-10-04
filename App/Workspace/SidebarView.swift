import SwiftUI
import WorkspaceKit

/// The single sidebar (design C): a Files / Search / Outline switch on top, the page below. Cmd-Shift-F jumps to the search
/// page, Cmd-Ctrl-O to the outline page.
struct SidebarView: View {
    @Bindable var model: WindowModel
    let preview: PreviewModel
    let status: EditorStatus
    let jump: (Int) -> Void
    /// Opens a search result and selects the match (`true` = regular tab, `false` = preview tab).
    let openHit: (SearchHit, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $model.sidebarSection) {
                Text("文件").tag(SidebarSection.files)
                Text("搜索").tag(SidebarSection.search)
                Text("大纲").tag(SidebarSection.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            switch model.sidebarSection {
            case .files:
                FilesPage(model: model)
            case .search:
                SearchPage(model: model, open: openHit)
            case .outline:
                OutlineList(preview: preview, status: status, jump: jump)
            }
        }
    }
}

/// Browse mode: filter, favorites, current location, recents. Workspace mode: the "folder · WORKSPACE" chip, filter, tree.
private struct FilesPage: View {
    let model: WindowModel

    var body: some View {
        let sidebar = model.sidebar
        let snapshot = sidebar.snapshot()
        VStack(spacing: 0) {
            if sidebar.isWorkspace { WorkspaceChip(model: model) }
            FilterField(sidebar: sidebar)
            if let count = snapshot.matchCount {
                Text(sidebar.showAllFiles ? "\(count) 项匹配" : "\(count) 项匹配 · 显示所有文件请点「全部」")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            FileTable(model: sidebar, items: snapshot.items, tableContext: tableContext)
        }
    }

    private var tableContext: SidebarTableContext {
        let session = model.controller.session
        let registry = WorkspaceRegistry.shared
        let dirty = session.tabs.filter { registry.document(for: $0.url)?.editedFlag.value == true }.map(\.id)
        return SidebarTableContext(
            activeKey: session.activeURL?.fileKey, previewKey: session.previewURL?.fileKey, dirtyKeys: Set(dirty),
            quartoEnabled: AppExtensions.host.flavors.contains { $0.id == "quarto" },
            query: model.sidebar.filter,
            favoriteKeys: Set(model.sidebar.stores.favorites.map { $0.url.fileKey }),
            anchorKeys: model.sidebar.folders.rootKeys)
    }
}

/// Design 02: a glass chip with the workspace's name; its menu adds folders, shows them in Finder, closes the workspace.
private struct WorkspaceChip: View {
    let model: WindowModel

    var body: some View {
        Menu {
            Button("添加文件夹到工作区…") { model.addWorkspaceFolders() }
            Button("在 Finder 中显示") { model.revealWorkspaceInFinder() }
            Divider()
            Button("关闭工作区") { model.sidebar.closeWorkspace() }
        } label: {
            HStack(spacing: 8) {
                Text(model.sidebar.folders.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("WORKSPACE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .accessibilityLabel("工作区 \(model.sidebar.folders.title)")
        .help(model.sidebar.folders.roots.map(\.path).joined(separator: "\n"))
    }
}

/// Filter box with the "All" switch (every file type, non-Markdown dimmed and opened in their own app).
private struct FilterField: View {
    @Bindable var sidebar: SidebarModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("筛选", text: $sidebar.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { sidebar.filter = "" }
            if !sidebar.filter.isEmpty {
                Button { sidebar.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除筛选")
            }
            AllFilesToggle(sidebar: sidebar)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// The "All" capsule in the filter and search fields: every file type instead of the Markdown family (non-Markdown dimmed
/// and opened in their own app). One switch for both pages.
struct AllFilesToggle: View {
    @Bindable var sidebar: SidebarModel

    var body: some View {
        Button { sidebar.showAllFiles.toggle() } label: {
            Text("全部")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(sidebar.showAllFiles ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(sidebar.showAllFiles ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("所有文件类型：树里非 Markdown 文件半透明、单击用默认 App 打开；搜索也会包含它们")
        .accessibilityLabel("显示所有文件")
        .accessibilityValue(sidebar.showAllFiles ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
    }
}
