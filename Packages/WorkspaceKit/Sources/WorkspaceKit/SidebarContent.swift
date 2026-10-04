import Foundation

/// One row of the Files page, top to bottom. The AppKit table renders these; building the list is a pure function so
/// the order and the empty / loading / filtering states are tested without a window.
public enum SidebarItem: Equatable, Sendable, Identifiable {
    public enum Section: String, Sendable { case favorites, location, recents }
    public enum Trailing: Equatable, Sendable { case none, add, clear, loading }

    case header(Section, title: String, trailing: Trailing)
    case favorite(ResolvedBookmark)
    /// The "current location" path bar (segments from the volume root; the last one is the folder shown).
    case pathBar([CurrentLocation.Segment], canGoUp: Bool)
    /// A tree row. `section` tells the table which menu and which click rules apply.
    case node(FileTreeModel.Row, section: Section)
    case recent(URL)
    /// Placeholder rows while a folder is being read (shown only after 300 ms).
    case skeleton(depth: Int, parent: String, index: Int)
    case unreadable(depth: Int, parent: String)
    /// An empty-state sentence for a section.
    case placeholder(Section, String)

    public var id: String {
        switch self {
        case .header(let s, _, _): return "header:\(s.rawValue)"
        case .favorite(let b): return "favorite:\(b.id.uuidString)"
        case .pathBar: return "pathbar"
        case .node(let row, let s): return "node:\(s.rawValue):\(row.node.id)"
        case .recent(let url): return "recent:\(url.fileKey)"
        case .skeleton(_, let parent, let i): return "skeleton:\(parent):\(i)"
        case .unreadable(_, let parent): return "unreadable:\(parent)"
        case .placeholder(let s, _): return "placeholder:\(s.rawValue)"
        }
    }

    /// Rows the user can select / act on.
    public var isSelectable: Bool {
        switch self {
        case .favorite, .node, .recent: return true
        default: return false
        }
    }
}

public struct SidebarSnapshot: Equatable, Sendable {
    public var items: [SidebarItem]
    /// Names matching the filter (nil: no filter active). Drives "4 matches".
    public var matchCount: Int?
}

public enum SidebarContent {
    /// Browse mode: favorites, current location (path bar + tree), recents. A filter hides the favorites and narrows the
    /// other two; `loading` are the folders being read, `skeletons` the ones that have taken longer than 300 ms.
    public static func browse(
        favorites: [ResolvedBookmark], location: CurrentLocation, tree: FileTreeModel, recents: [URL], query: String,
        skeletons: Set<String>, rootTitle: String = "/", canGoUp: Bool? = nil
    ) -> SidebarSnapshot {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtering = !needle.isEmpty
        var items: [SidebarItem] = []
        var matches = 0

        if !filtering {
            items.append(.header(.favorites, title: L10n.favorites, trailing: .add))
            items += favorites.map(SidebarItem.favorite)
            if favorites.isEmpty { items.append(.placeholder(.favorites, L10n.dragFoldersHere)) }
        }

        let isReading = location.directory.map { !tree.isLoaded($0) && skeletons.contains($0.fileKey) } ?? false
        items.append(.header(.location, title: L10n.currentLocation, trailing: isReading ? .loading : .none))
        if let directory = location.directory {
            items.append(.pathBar(location.segments(rootTitle: rootTitle), canGoUp: canGoUp ?? (location.parent != nil)))
            if tree.unreadable.contains(directory.fileKey) {
                items.append(.unreadable(depth: 0, parent: directory.fileKey))
            } else if !tree.isLoaded(directory) {
                if isReading { items += skeletonRows(depth: 0, parent: directory.fileKey) }
            } else {
                let rows: [FileTreeModel.Row]
                if filtering {
                    let result = tree.filtered(by: needle, showRoots: false)
                    rows = result.rows
                    matches += result.matchCount
                } else {
                    rows = tree.rows(showRoots: false)
                }
                items += decorate(rows, tree: tree, skeletons: skeletons, section: .location)
                if rows.isEmpty { items.append(.placeholder(.location, filtering ? L10n.noMatches : L10n.folderIsEmpty)) }
            }
        } else {
            items.append(.placeholder(.location, L10n.noDocumentOpen))
        }

        let shownRecents = filtering ? recents.filter { matchesName($0.lastPathComponent, needle) } : recents
        if filtering { matches += shownRecents.count }
        if !filtering || !shownRecents.isEmpty {
            items.append(.header(.recents, title: L10n.recents, trailing: recents.isEmpty ? .none : .clear))
            items += shownRecents.map(SidebarItem.recent)
            if recents.isEmpty { items.append(.placeholder(.recents, L10n.noRecents)) }
        }
        return SidebarSnapshot(items: items, matchCount: filtering ? matches : nil)
    }

    /// Workspace mode: only the trees of the workspace folders.
    public static func workspace(tree: FileTreeModel, query: String, skeletons: Set<String>) -> SidebarSnapshot {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtering = !needle.isEmpty
        let rows: [FileTreeModel.Row]
        var matches: Int?
        if filtering {
            let result = tree.filtered(by: needle)
            rows = result.rows
            matches = result.matchCount
        } else {
            rows = tree.rows()
        }
        var items = decorate(rows, tree: tree, skeletons: skeletons, section: .location)
        if filtering, rows.isEmpty { items = [.placeholder(.location, L10n.noMatches)] }
        return SidebarSnapshot(items: items, matchCount: matches)
    }

    public static func matchesName(_ name: String, _ needle: String) -> Bool {
        name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Rows plus the notices under an opened folder that has nothing to show yet: skeleton while it is being read (after
    /// 300 ms), a hint when it cannot be read.
    private static func decorate(_ rows: [FileTreeModel.Row], tree: FileTreeModel, skeletons: Set<String>, section: SidebarItem.Section) -> [SidebarItem] {
        var out: [SidebarItem] = []
        for row in rows {
            out.append(.node(row, section: section))
            guard row.node.isDirectory, tree.isExpanded(row.node.url) else { continue }
            let key = row.node.id
            if tree.unreadable.contains(key) {
                out.append(.unreadable(depth: row.depth + 1, parent: key))
            } else if !tree.isLoaded(row.node.url), skeletons.contains(key) {
                out += skeletonRows(depth: row.depth + 1, parent: key)
            }
        }
        return out
    }

    private static func skeletonRows(depth: Int, parent: String) -> [SidebarItem] {
        (0..<3).map { .skeleton(depth: depth, parent: parent, index: $0) }
    }
}
