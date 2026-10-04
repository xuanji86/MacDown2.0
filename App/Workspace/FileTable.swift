import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// What the rows need besides the items themselves; a change redraws the table.
struct SidebarTableContext: Equatable {
    var activeKey: String?
    var previewKey: String?
    var dirtyKeys: Set<String>
    var quartoEnabled: Bool
    var query: String
    var favoriteKeys: Set<String>
    /// Workspace roots: they can be neither renamed nor trashed from here.
    var anchorKeys: Set<String>
}

extension SidebarItem {
    var fileURL: URL? {
        switch self {
        case .favorite(let b): return b.url
        case .node(let row, _): return row.node.url
        case .recent(let url): return url
        default: return nil
        }
    }
}

/// The Files page's list. An AppKit table rather than a SwiftUI `List` because the keyboard is a requirement (arrows,
/// Return, Space for Quick Look) and AppKit's responder chain does exactly that without guessing: `keyDown`, the
/// `QLPreviewPanel` controller protocol, `menu(for:)` and the drag-and-drop validation are all plain overrides.
struct FileTable: NSViewRepresentable {
    let model: SidebarModel
    let items: [SidebarItem]
    let tableContext: SidebarTableContext

    func makeCoordinator() -> FileTableCoordinator { FileTableCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = FileTableView()
        table.coordinator = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = SidebarStyle.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.floatsGroupRows = false
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.action = #selector(FileTableCoordinator.clicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setAccessibilityLabel("文件")
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.update(items: items, context: tableContext)
    }
}

// MARK: - Table

final class FileTableView: NSTableView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    weak var coordinator: FileTableCoordinator?

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    // MARK: Quick Look (Space)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func refreshQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self { panel.reloadData() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    private var previewURLs: [URL] { selectedRowIndexes.compactMap { coordinator?.items[$0].fileURL } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = previewURLs
        return index < urls.count ? urls[index] as NSURL : nil
    }
}

// MARK: - Coordinator

@MainActor
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: SidebarModel
    weak var table: FileTableView?
    private(set) var items: [SidebarItem] = []
    private var ctx = SidebarTableContext(activeKey: nil, previewKey: nil, dirtyKeys: [], quartoEnabled: false, query: "", favoriteKeys: [], anchorKeys: [])
    /// The row being renamed; the table is not reloaded meanwhile (that would destroy the editor).
    private var editingKey: String?
    private var deferred: (items: [SidebarItem], context: SidebarTableContext)?

    init(model: SidebarModel) { self.model = model }

    // MARK: Updates

    func update(items new: [SidebarItem], context newContext: SidebarTableContext) {
        if editingKey != nil {
            deferred = (new, newContext)
            return
        }
        if new != items || newContext != ctx {
            let selected = selectedIDs()
            items = new
            ctx = newContext
            table?.reloadData()
            restoreSelection(selected)
        }
        consumePending()
    }

    private func selectedIDs() -> [String] { (table?.selectedRowIndexes ?? []).compactMap { items.indices.contains($0) ? items[$0].id : nil } }

    private func restoreSelection(_ ids: [String]) {
        guard let table, !ids.isEmpty else { return }
        let rows = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// A new item to rename, or a renamed one to select, as soon as its row exists. Deferred a turn: this runs inside a
    /// SwiftUI update and must not write observable state.
    private func consumePending() {
        guard model.pendingEdit != nil || model.pendingSelect != nil else { return }
        if let key = model.pendingEdit, let row = rowIndex(forFileKey: key) {
            DispatchQueue.main.async { [self] in
                model.pendingEdit = nil
                beginRename(row: row)
            }
        } else if let key = model.pendingSelect, let row = rowIndex(forFileKey: key) {
            DispatchQueue.main.async { [self] in
                model.pendingSelect = nil
                table?.selectRowIndexes([row], byExtendingSelection: false)
                table?.scrollRowToVisible(row)
            }
        }
    }

    private func rowIndex(forFileKey key: String) -> Int? {
        items.firstIndex { item in
            switch item {
            case .node(let row, _): return row.node.id == key
            case .recent(let url): return url.fileKey == key
            default: return false
            }
        }
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header: return 28
        case .pathBar: return 28
        case .placeholder: return 44
        case .skeleton, .unreadable: return 22
        default: return SidebarStyle.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].isSelectable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SidebarRowView()
        view.isActiveDocument = ctx.activeKey != nil && items[row].fileURL?.fileKey == ctx.activeKey
        return view
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { items[row].fileURL?.lastPathComponent }

    func tableViewSelectionDidChange(_ notification: Notification) { table?.refreshQuickLook() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let section, let title, let trailing):
            let cell = reuse(HeaderCellView.identifier, as: HeaderCellView.self)
            cell.configure(title: title, trailing: trailing) { [weak self] in
                switch section {
                case .favorites: self?.chooseFavoriteFolder()
                case .recents: SidebarStores.shared.clearRecents()
                case .location: break
                }
            }
            return cell
        case .pathBar(let segments, let canGoUp):
            let cell = reuse(PathBarCellView.identifier, as: PathBarCellView.self)
            cell.configure(segments: segments, canGoUp: canGoUp, goUp: { [weak self] in self?.model.goUp() }, go: { [weak self] in self?.model.navigate(to: $0) })
            return cell
        case .favorite(let b):
            return fileCell(content(name: Self.favoriteName(b.url), url: b.url, isDirectory: true, depth: 0, tree: false), row: row)
        case .node(let r, _):
            var c = content(name: r.node.name, url: r.node.url, isDirectory: r.node.isDirectory, depth: r.depth, tree: true)
            c.hasChevron = r.node.isDirectory
            c.isExpanded = r.isExpanded || model.tree.isExpanded(r.node.url)
            c.isQuarto = r.node.isQuartoProject && ctx.quartoEnabled
            return fileCell(c, row: row)
        case .recent(let url):
            return fileCell(content(name: url.lastPathComponent, url: url, isDirectory: false, depth: 0, tree: false), row: row)
        case .skeleton(let depth, _, let i):
            let cell = reuse(NoticeCellView.identifier, as: NoticeCellView.self)
            cell.configure(text: nil, depth: depth, skeletonIndex: i)
            return cell
        case .unreadable(let depth, _):
            let cell = reuse(NoticeCellView.identifier, as: NoticeCellView.self)
            cell.configure(text: "无法读取这个文件夹（可能没有权限）", depth: depth, skeletonIndex: nil)
            return cell
        case .placeholder(_, let text):
            let cell = reuse(NoticeCellView.identifier, as: NoticeCellView.self)
            cell.configure(text: text, depth: 0, skeletonIndex: nil)
            return cell
        }
    }

    private func reuse<T: NSView>(_ id: NSUserInterfaceItemIdentifier, as type: T.Type) -> T {
        (table?.makeView(withIdentifier: id, owner: nil) as? T) ?? T(frame: .zero)
    }

    private static func favoriteName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    private func content(name: String, url: URL, isDirectory: Bool, depth: Int, tree: Bool) -> FileCellView.Content {
        let key = url.fileKey
        let openable = isDirectory || model.isOpenable(url)
        let symbol: String
        var tint: NSColor = .secondaryLabelColor
        if isDirectory {
            symbol = url.path.hasSuffix("com~apple~CloudDocs") ? "icloud.fill" : "folder.fill"
            tint = SidebarStyle.folderTint
        } else if url.pathExtension.lowercased() == "qmd" {
            symbol = "doc.text"
            tint = SidebarStyle.quartoTint
        } else {
            symbol = openable ? "doc.text" : "doc"
        }
        var c = FileCellView.Content(name: name, symbol: symbol, tint: tint)
        c.depth = depth
        c.isTree = tree
        c.isDirty = ctx.dirtyKeys.contains(key)
        c.isPreview = !isDirectory && ctx.previewKey == key
        c.isDimmed = !openable
        c.query = ctx.query.trimmingCharacters(in: .whitespaces)
        c.help = url.path
        return c
    }

    private func fileCell(_ c: FileCellView.Content, row: Int) -> FileCellView {
        let cell = reuse(FileCellView.identifier, as: FileCellView.self)
        cell.configure(c) { [weak self] in
            if self?.items.indices.contains(row) == true, let url = self?.items[row].fileURL { self?.model.toggle(url) }
        }
        cell.onEnd = nil
        return cell
    }

    // MARK: Clicks and keys

    @objc func clicked(_ sender: Any?) {
        guard let table else { return }
        let row = table.clickedRow
        guard row >= 0, items.indices.contains(row) else { return }
        activate(row: row, clickCount: NSApp.currentEvent?.clickCount ?? 1)
    }

    /// Single click: preview tab (folders open or close); double click / Return: regular tab.
    private func activate(row: Int, clickCount: Int) {
        switch items[row] {
        case .favorite(let b): model.navigate(to: b.url)
        case .node(let r, _):
            if r.node.isDirectory {
                if clickCount <= 1 { model.toggle(r.node.url) }
            } else {
                model.open(r.node.url, pinned: clickCount >= 2)
            }
        case .recent(let url): model.open(url, pinned: clickCount >= 2)
        default: break
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, let table else { return false }
        let row = table.selectedRow
        guard row >= 0, items.indices.contains(row) else { return false }
        switch event.keyCode {
        case 123:  // ←
            collapseOrSelectParent(row: row)
        case 124:  // →
            expandOrSelectFirstChild(row: row)
        case 36, 76:  // Return, Enter
            if case .node(let r, _) = items[row], r.node.isDirectory { model.toggle(r.node.url) } else { activate(row: row, clickCount: 2) }
        case 49:  // Space
            table.toggleQuickLook()
        default:
            return false
        }
        return true
    }

    private func collapseOrSelectParent(row: Int) {
        guard case .node(let r, let section) = items[row] else { return }
        if r.node.isDirectory, model.tree.isExpanded(r.node.url) {
            model.setExpanded(r.node.url, false)
            return
        }
        // Finder: ← on a closed folder or a file moves to the folder that holds it.
        guard r.depth > 0 else { return }
        var i = row - 1
        while i >= 0 {
            if case .node(let candidate, let s) = items[i], s == section, candidate.depth < r.depth {
                table?.selectRowIndexes([i], byExtendingSelection: false)
                table?.scrollRowToVisible(i)
                return
            }
            i -= 1
        }
    }

    private func expandOrSelectFirstChild(row: Int) {
        guard case .node(let r, _) = items[row], r.node.isDirectory else { return }
        if !model.tree.isExpanded(r.node.url) {
            model.setExpanded(r.node.url, true)
        } else if row + 1 < items.count, case .node(let next, _) = items[row + 1], next.depth > r.depth {
            table?.selectRowIndexes([row + 1], byExtendingSelection: false)
            table?.scrollRowToVisible(row + 1)
        }
    }

    // MARK: Context menu

    private final class Payload: NSObject {
        let action: FileAction
        let url: URL
        let isDirectory: Bool
        init(_ action: FileAction, _ url: URL, _ isDirectory: Bool) {
            self.action = action
            self.url = url
            self.isDirectory = isDirectory
        }
    }

    func menu(forRow row: Int) -> NSMenu? {
        var target: (url: URL, isDirectory: Bool, anchor: Bool, favorite: Bool)?
        if row >= 0, items.indices.contains(row) {
            table?.selectRowIndexes([row], byExtendingSelection: false)
            switch items[row] {
            case .favorite(let b): target = (b.url, true, true, true)
            case .node(let r, _): target = (r.node.url, r.node.isDirectory, ctx.anchorKeys.contains(r.node.id), ctx.favoriteKeys.contains(r.node.id))
            case .recent(let url): target = (url, false, false, false)
            default: break
            }
        } else if let folder = model.isWorkspace ? model.folders.roots.first : model.location.directory {
            target = (folder, true, true, ctx.favoriteKeys.contains(folder.fileKey))  // empty space: the folder shown
        }
        guard let target else { return nil }
        let actions = SidebarContextMenu.actions(for: target.url, isDirectory: target.isDirectory, isAnchor: target.anchor, isFavorite: target.favorite)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ action: FileAction) {
            let item = NSMenuItem(title: Self.title(action), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Payload(action, target.url, target.isDirectory)
            if action == .moveToTrash {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
            }
            menu.addItem(item)
        }
        for action in actions {
            if [.newFile, .rename, .addToFavorites, .removeFromFavorites].contains(action), !menu.items.isEmpty, !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }
            add(action)
        }
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload else { return }
        model.perform(p.action, on: p.url, isDirectory: p.isDirectory)
    }

    private static func title(_ action: FileAction) -> String {
        switch action {
        case .revealInFinder: return "在 Finder 中显示"
        case .copyPath: return "拷贝路径"
        case .newFile: return "新建文件"
        case .newFolder: return "新建文件夹"
        case .rename: return "重命名"
        case .moveToTrash: return "移到废纸篓"
        case .addToFavorites: return "添加到收藏"
        case .removeFromFavorites: return "从收藏移除"
        }
    }

    // MARK: Renaming

    private func beginRename(row: Int) {
        guard let table, items.indices.contains(row), let url = items[row].fileURL,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView else { return }
        if case .favorite = items[row] { return }
        if case .node(let r, _) = items[row], ctx.anchorKeys.contains(r.node.id) { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        editingKey = url.fileKey
        cell.onEnd = { [weak self] name in
            guard let self else { return }
            cell.onEnd = nil
            editingKey = nil
            model.finishRename(url, name: name)
            if let deferred { self.deferred = nil; update(items: deferred.items, context: deferred.context) }
        }
        let isFolder: Bool = { if case .node(let r, _) = items[row] { return r.node.isDirectory }; return false }()
        cell.beginEditing(selectingBaseName: !isFolder)
    }

    // MARK: Favorites

    private func chooseFavoriteFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.model.addFavorite(url) }
        }
        if let window = table?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Rows where a dropped folder becomes a favorite: the favorites section, `start` is the first row of it.
    private var favoritesZone: (start: Int, count: Int)? {
        guard let header = items.firstIndex(where: { if case .header(.favorites, _, _) = $0 { return true } else { return false } }) else { return nil }
        return (header + 1, items.filter { if case .favorite = $0 { return true } else { return false } }.count)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if case .favorite(let b) = items[row] { return b.url as NSURL }  // so favorites can be reordered by dragging
        return nil
    }

    private func droppedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return [] }
        if let zone = favoritesZone, urls.contains(where: OpenRouter.isFolder), (zone.start...(zone.start + zone.count)).contains(row) {
            tableView.setDropRow(row, dropOperation: .above)  // the insertion line
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)  // anywhere else: the whole sidebar takes it (a workspace / tabs)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        if row >= 0, let zone = favoritesZone, dropOperation == .above, urls.contains(where: OpenRouter.isFolder) {
            model.dropFavorites(urls.filter(OpenRouter.isFolder), at: row - zone.start)
        } else {
            model.drop(urls)
        }
        return true
    }
}
