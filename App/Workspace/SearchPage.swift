import SwiftUI
import WorkspaceKit

/// The sidebar's search page (⌘⇧F): the query field, a status line and the results grouped by file. Return or a click opens
/// the result as a tab and selects the match in the editor; ↓ moves from the field into the list, Esc clears.
struct SearchPage: View {
    let model: WindowModel
    /// Opens the result in a tab and selects the match; `true` = a regular tab (Return), `false` = the preview tab (click).
    let open: (SearchHit, Bool) -> Void

    fileprivate enum Focus { case field, list }
    @FocusState private var focus: Focus?

    var body: some View {
        let search = model.search
        VStack(spacing: 0) {
            SearchField(search: search, sidebar: model.sidebar, focus: $focus, submit: submit)
            SearchStatusLine(search: search)
            if search.groups.isEmpty {
                Spacer(minLength: 0)
            } else {
                results(search)
            }
        }
        .onAppear {
            focus = .field
            search.revalidate()
        }
        .onChange(of: search.focusTick) { focus = .field }
        // The folders or the file filter changed while this page is up (a different folder with the same name, "全部"):
        // the old results would be misleading. While another page is up, `revalidate` catches up when this one returns.
        .onChange(of: search.scopeSnapshot) { search.start() }
    }

    private func results(_ search: SearchModel) -> some View {
        @Bindable var search = search
        return List(selection: $search.selection) {
            ForEach(search.groups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        SearchHitRow(hit: hit)
                            .tag(hit.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                search.selection = hit.id
                                open(hit, false)
                            }
                            .onTapGesture(count: 2) { open(hit, true) }
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    SearchGroupHeader(group: group, badge: group.hits.first.map(search.badge(for:)) ?? "")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focused($focus, equals: .list)
        .onKeyPress(.return) {
            guard let hit = search.selectedHit else { return .ignored }
            open(hit, true)
            return .handled
        }
        .onExitCommand { focus = .field }
        .accessibilityLabel("搜索结果")
    }

    /// Return in the field: the selected result, else the first one.
    private func submit() {
        let search = model.search
        if let hit = search.selectedHit ?? search.hits.first { open(hit, true) } else { search.start() }
    }
}

private struct SearchField: View {
    @Bindable var search: SearchModel
    let sidebar: SidebarModel
    var focus: FocusState<SearchPage.Focus?>.Binding
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("在文件中搜索", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .field)
                .onSubmit(submit)
                .onExitCommand { search.clearQuery() }
                .onKeyPress(.downArrow) {
                    guard !search.groups.isEmpty else { return .ignored }
                    focus.wrappedValue = .list
                    return .handled
                }
                .accessibilityLabel("在文件中搜索")
                .accessibilityHint("输入后自动搜索。双引号括起短语，减号开头排除，打开正则开关用正则表达式。按下箭头进入结果")
            if !search.query.isEmpty {
                Button { search.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Button { search.isRegex.toggle() } label: {
                Text(".*")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(search.isRegex ? Color.white : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(search.isRegex ? Color.accentColor : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("正则表达式（不区分大小写，按行匹配）")
            .accessibilityLabel("正则表达式")
            .accessibilityValue(search.isRegex ? "开" : "关")
            .accessibilityAddTraits(.isToggle)
            AllFilesToggle(sidebar: sidebar)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// "42 处匹配 · 7 个文件", or why there is nothing.
private struct SearchStatusLine: View {
    let search: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch search.status {
            case .idle:
                line(search.scopeTitle.isEmpty
                    ? "先打开一个文件夹，或打开一个文档，再搜索它所在的文件夹"
                    : "搜索「\(search.scopeTitle)」里的文件内容。\"短语\"、-排除词")
            case .noScope:
                line("没有可搜索的文件夹：先打开一个文件夹，或打开一个文档")
            case .searching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(search.hitCount == 0 ? "正在搜索…" : "正在搜索… 已找到 \(search.hitCount) 处")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            case .finished:
                line(search.hitCount == 0 ? "没有匹配项" : "\(search.hitCount) 处匹配 · \(search.groups.count) 个文件")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityLabel("搜索出错：\(message)")
            }
            if let limit = search.truncation {
                line(SearchError.truncated(limit).errorDescription ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SearchGroupHeader: View {
    let group: SearchGroup
    let badge: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.file.lastPathComponent).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                if !group.folder.isEmpty {
                    Text(group.folder).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            Text("\(group.hits.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            if !badge.isEmpty {
                // Where the result came from (the built-in search; other providers show their own name).
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.file.lastPathComponent)，\(group.hits.count) 处匹配" + (badge.isEmpty ? "" : "，来源\(badge)"))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let line = hit.line {
                Text("\(line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
            Text(highlighted)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((hit.line.map { "第 \($0) 行：" } ?? "") + hit.snippet)
        .accessibilityHint("按回车打开并定位")
        .accessibilityAddTraits(.isButton)
    }

    private var highlighted: AttributedString {
        var text = AttributedString(hit.snippet)
        for range in hit.highlights {
            if let r = Range(NSRange(location: range.lowerBound, length: range.count), in: text) {
                text[r].backgroundColor = Color(red: 1, green: 0.84, blue: 0.04).opacity(0.45)
                text[r].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return text
    }
}
