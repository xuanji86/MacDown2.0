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
        // The folders or the file filter changed while this page is up (a different folder with the same name, "All"):
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
        .accessibilityLabel("Search Results")
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
            TextField("Search in Files", text: $search.query)
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
                .accessibilityLabel("Search in Files")
                .accessibilityHint("Searches as you type. Put a phrase in double quotes, start a word with a minus sign to exclude it, and turn the regular expression switch on to use one. Press the down arrow to go to the results")
            if !search.query.isEmpty {
                Button { search.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
            Button { search.isRegex.toggle() } label: {
                Text(verbatim: ".*")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(search.isRegex ? Color.white : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(search.isRegex ? Color.accentColor : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Regular expression (case-insensitive, matched line by line)")
            .accessibilityLabel("Regular Expression")
            .accessibilityValue(.onOff(search.isRegex))
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

/// "42 matches in 7 files", or why there is nothing.
private struct SearchStatusLine: View {
    let search: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch search.status {
            case .idle:
                line(search.scopeTitle.isEmpty
                    ? String(localized: "Open a folder, or open a document, then search the folder it is in")
                    : String(localized: "Search the contents of the files in “\(search.scopeTitle)”. \"phrase\", -excluded"))
            case .noScope:
                line(String(localized: "No folder to search: open a folder or a document first"))
            case .searching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(searchingLine)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            case .finished:
                line(search.hitCount == 0
                    ? String(localized: "No matches")
                    : String(localized: "\(search.hitCount) matches in \(search.groups.count) files"))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Search error: \(message)")
            }
            if let limit = search.truncation {
                line(SearchError.truncated(limit).errorDescription ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var searchingLine: LocalizedStringKey {
        search.hitCount == 0 ? "Searching…" : "Searching… \(search.hitCount) found so far"
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SearchGroupHeader: View {
    let group: SearchGroup
    let badge: String

    private var groupLabel: String {
        let name = group.file.lastPathComponent, count = group.hits.count
        return badge.isEmpty
            ? String(localized: "\(name), \(count) matches")
            : String(localized: "\(name), \(count) matches, from \(badge)")
    }

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
            Text(verbatim: "\(group.hits.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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
        .accessibilityLabel(groupLabel)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let line = hit.line {
                Text(verbatim: "\(line)")
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
        .accessibilityLabel((hit.line.map { String(localized: "Line \($0): ") } ?? "") + hit.snippet)
        .accessibilityHint("Press Return to open the file and select the match")
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
