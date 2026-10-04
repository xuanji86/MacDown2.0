import Foundation

public struct FileNode: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isDirectory: Bool
    /// A folder holding `_quarto.yml` / `_quarto.yaml` (the Q badge; the UI shows it only while the Quarto extension is on).
    public let isQuartoProject: Bool
    public var id: String { url.fileKey }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool, isQuartoProject: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isQuartoProject = isQuartoProject
    }
}

/// What the tree shows. By default only folders and the Markdown family; `showAllFiles` lifts the extension filter
/// (and shows dot files). The ignore rules apply in both modes: `node_modules` stays out even with "show all".
public struct FileTreeOptions: Sendable, Equatable {
    public var showAllFiles: Bool
    public var markdownExtensions: Set<String>
    public var ignore: IgnoreRules

    public init(showAllFiles: Bool = false, markdownExtensions: Set<String> = ["md", "markdown", "qmd", "txt"], ignore: IgnoreRules = .default) {
        self.showAllFiles = showAllFiles
        self.markdownExtensions = markdownExtensions
        self.ignore = ignore
    }

    func includes(name: String, isDirectory: Bool) -> Bool {
        if ignore.ignores(name: name, isDirectory: isDirectory) { return false }
        if showAllFiles { return true }
        if name.hasPrefix(".") { return false }
        return isDirectory || markdownExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

public enum DirectoryLister {
    /// One level of `directory`, filtered and sorted: folders first, then Finder-style natural order
    /// ("file2" before "file10", case-insensitive). Static and free of shared state so callers may run it off the main
    /// thread and hand the result to `FileTreeModel.setChildren`.
    public static func list(_ directory: URL, options: FileTreeOptions) throws -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        var nodes: [FileNode] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {  // a link to a folder browses like a folder
                var target: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &target) && target.boolValue
            }
            if values?.isPackage == true { isDirectory = false }  // .app, .pages: a file as far as the user is concerned
            if options.includes(name: url.lastPathComponent, isDirectory: isDirectory) {
                // Built from `directory`, not taken from the listing, so a node's spelling always extends its parent's.
                let child = directory.appending(path: url.lastPathComponent, directoryHint: isDirectory ? .isDirectory : .notDirectory)
                nodes.append(FileNode(url: child, isDirectory: isDirectory, isQuartoProject: isDirectory && isQuartoProject(child)))
            }
        }
        return nodes.sorted(by: precedes)
    }

    /// One `stat` per folder in a listing, so the badge costs nothing for files (the bulk of a big directory).
    public static func isQuartoProject(_ directory: URL) -> Bool {
        ["_quarto.yml", "_quarto.yaml"].contains { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    static func precedes(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name  // total order, so equal-looking names never reshuffle
        }
    }
}

/// The outcome of reading one directory off the main thread; `FileTreeModel.apply` installs it.
public struct DirectoryListing: Sendable {
    public let directory: URL
    /// nil: the directory exists but could not be read.
    public let nodes: [FileNode]?
    public let exists: Bool

    public init(directory: URL, nodes: [FileNode]?, exists: Bool) {
        self.directory = directory
        self.nodes = nodes
        self.exists = exists
    }

    public static func read(_ directory: URL, options: FileTreeOptions) -> DirectoryListing {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return DirectoryListing(directory: directory, nodes: nil, exists: false)
        }
        return DirectoryListing(directory: directory, nodes: try? DirectoryLister.list(directory, options: options), exists: true)
    }
}

/// Reads the directories a name filter has not seen yet, so a match deep in the tree shows up without the user having
/// to open every folder first. Pure function of its inputs: run it off the main thread, install the result with
/// `FileTreeModel.merge`.
public enum DirectoryCrawler {
    // lazy: 2,000 folders / 12 levels, then it stops (a filter over a whole home folder is not a search engine); upgrade: Spotlight / the §4.12 search backend
    public static func crawl(
        _ model: FileTreeModel, maxDirectories: Int = 2000, maxDepth: Int = 12, isCancelled: @Sendable () -> Bool = { false }
    ) -> [DirectoryListing] {
        var out: [DirectoryListing] = []
        var seen = Set<String>()  // real paths, so a symlink loop is read once
        var queue = model.roots.map { ($0, 0) }
        var head = 0
        while head < queue.count, out.count < maxDirectories, !isCancelled() {
            let (directory, depth) = queue[head]
            head += 1
            guard seen.insert(directory.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
            let nodes: [FileNode]
            if let known = model.children(of: directory) {
                nodes = known
            } else {
                let read = DirectoryListing.read(directory, options: model.options)
                out.append(read)
                nodes = read.nodes ?? []
            }
            if depth < maxDepth { queue += nodes.filter(\.isDirectory).map { ($0.url, depth + 1) } }
        }
        return out
    }
}

/// The sidebar tree: one or more roots, directories loaded on first expansion. A plain value, so it is trivially
/// testable and safe to hand across threads; the UI owns one and mutates it on the main actor.
public struct FileTreeModel: Sendable {
    public struct Row: Sendable, Equatable {
        public let node: FileNode
        public let depth: Int
        public let isExpanded: Bool
    }

    public private(set) var roots: [URL] = []
    public private(set) var options: FileTreeOptions
    /// Directories whose listing could not be read (permissions, vanished). They show as empty.
    public private(set) var unreadable: Set<String> = []
    private var listings: [String: [FileNode]] = [:]
    private var expanded: Set<String> = []

    public init(roots: [URL] = [], options: FileTreeOptions = FileTreeOptions()) {
        self.options = options
        for root in roots { addRoot(root) }
    }

    // MARK: Roots

    /// Adds a root (expanded and loaded). A root that is already present is ignored. Returns whether it was added.
    /// `load: false` leaves the reading to the caller (the app reads off the main thread).
    @discardableResult
    public mutating func addRoot(_ url: URL, load: Bool = true) -> Bool {
        guard !roots.contains(where: { $0.fileKey == url.fileKey }) else { return false }
        roots.append(url)
        setExpanded(url, true, load: load)
        return true
    }

    public mutating func removeRoot(_ url: URL) {
        roots.removeAll { $0.fileKey == url.fileKey }
        drop(url.fileKey)
    }

    // MARK: Loading

    /// The loaded listing of `directory`; nil when it has not been read yet.
    public func children(of directory: URL) -> [FileNode]? { listings[directory.fileKey] }

    public func isLoaded(_ directory: URL) -> Bool { listings[directory.fileKey] != nil }

    /// Whether `url` is a root or inside one.
    public func isUnderRoot(_ url: URL) -> Bool {
        let key = url.fileKey
        return roots.contains { root in
            let r = root.fileKey
            return key == r || key.hasPrefix(r == "/" ? "/" : r + "/")
        }
    }

    /// Installs listings read elsewhere (`DirectoryListing.read`). A directory that is gone is dropped with everything
    /// below it; one outside the roots (the roots changed while it was being read) is ignored.
    public mutating func apply(_ read: [DirectoryListing]) {
        for item in read where isUnderRoot(item.directory) {
            if item.exists { setChildren(item.nodes ?? [], of: item.directory, readable: item.nodes != nil) } else { drop(item.directory.fileKey) }
        }
    }

    /// Crawler results: only directories that are still unread (a listing that arrived meanwhile is newer).
    public mutating func merge(_ read: [DirectoryListing]) {
        apply(read.filter { !isLoaded($0.directory) })
    }

    @discardableResult
    public mutating func loadChildren(of directory: URL) -> [FileNode] {
        if let cached = listings[directory.fileKey] { return cached }
        let listed = try? DirectoryLister.list(directory, options: options)
        setChildren(listed ?? [], of: directory, readable: listed != nil)
        return listed ?? []
    }

    /// Installs a listing produced elsewhere (e.g. `DirectoryLister.list` on a background queue).
    public mutating func setChildren(_ nodes: [FileNode], of directory: URL, readable: Bool = true) {
        let key = directory.fileKey
        let old = listings[key] ?? []
        listings[key] = nodes
        if readable { unreadable.remove(key) } else { unreadable.insert(key) }
        let kept = Set(nodes.map(\.id))
        for gone in old where gone.isDirectory && !kept.contains(gone.id) { drop(gone.id) }
    }

    /// Re-reads the given directories after file system events. Directories never loaded are skipped (they will be
    /// read fresh when expanded); directories that no longer exist are dropped with everything below them.
    public mutating func reload(_ directories: Set<URL>) {
        for directory in directories where listings[directory.fileKey] != nil {
            relist(directory)
        }
    }

    /// `relist: false` forgets every listing instead of re-reading them here; the caller reads the expanded ones again
    /// (`expandedDirectories`) off the main thread.
    public mutating func setOptions(_ new: FileTreeOptions, relist reread: Bool = true) {
        guard new != options else { return }
        options = new
        if reread {
            for key in Array(listings.keys) { relist(URL(fileURLWithPath: key, isDirectory: true)) }
        } else {
            listings = [:]
            unreadable = []
        }
    }

    public var expandedDirectories: [URL] { expanded.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) } }

    private mutating func relist(_ directory: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            drop(directory.fileKey)
            return
        }
        let listed = try? DirectoryLister.list(directory, options: options)
        setChildren(listed ?? [], of: directory, readable: listed != nil)
    }

    // MARK: Expansion

    public func isExpanded(_ directory: URL) -> Bool { expanded.contains(directory.fileKey) }

    public mutating func setExpanded(_ directory: URL, _ isExpanded: Bool, load: Bool = true) {
        if isExpanded {
            expanded.insert(directory.fileKey)
            if load { loadChildren(of: directory) }
        } else {
            expanded.remove(directory.fileKey)
        }
    }

    // MARK: Flattened view

    /// Visible rows in display order, roots first. Only expanded directories contribute their children.
    /// `showRoots: false` lists the (single) root's contents at depth 0 without a row for the root itself.
    public func rows(showRoots: Bool = true) -> [Row] {
        var out: [Row] = []
        func walk(_ node: FileNode, depth: Int) {
            let open = node.isDirectory && expanded.contains(node.id)
            out.append(Row(node: node, depth: depth, isExpanded: open))
            if open { for child in listings[node.id] ?? [] { walk(child, depth: depth + 1) } }
        }
        for root in roots {
            if showRoots {
                walk(rootNode(root), depth: 0)
            } else if expanded.contains(root.fileKey) {
                for child in listings[root.fileKey] ?? [] { walk(child, depth: 0) }
            }
        }
        return out
    }

    func rootNode(_ root: URL) -> FileNode {
        FileNode(url: root, isDirectory: true, isQuartoProject: DirectoryLister.isQuartoProject(root))
    }

    public struct FilterResult: Sendable, Equatable {
        public let rows: [Row]
        /// Items whose own name matches (the folders shown only because something inside matches do not count).
        public let matchCount: Int
    }

    /// The tree narrowed to names containing `query` (case and diacritics ignored): every match with the folders above
    /// it, those opened. Looks at every directory read so far, expanded or not. A match inside a folder that has not
    /// been read is invisible until `DirectoryCrawler` has run.
    public func filtered(by query: String, showRoots: Bool = true) -> FilterResult {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return FilterResult(rows: rows(showRoots: showRoots), matchCount: 0) }
        var count = 0
        func matches(_ name: String) -> Bool { name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        func visit(_ node: FileNode, depth: Int) -> [Row] {
            var below: [Row] = []
            if node.isDirectory { for child in listings[node.id] ?? [] { below += visit(child, depth: depth + 1) } }
            let own = matches(node.name)
            if own { count += 1 }
            guard own || !below.isEmpty else { return [] }
            return [Row(node: node, depth: depth, isExpanded: !below.isEmpty)] + below
        }
        var out: [Row] = []
        for root in roots {
            if showRoots {
                out += visit(rootNode(root), depth: 0)
            } else {
                for child in listings[root.fileKey] ?? [] { out += visit(child, depth: 0) }
            }
        }
        return FilterResult(rows: out, matchCount: count)
    }

    // MARK: Internals

    /// Forgets `key` and every cached listing / expansion state below it.
    private mutating func drop(_ key: String) {
        let prefix = key == "/" ? "/" : key + "/"
        listings = listings.filter { $0.key != key && !$0.key.hasPrefix(prefix) }
        expanded = expanded.filter { $0 != key && !$0.hasPrefix(prefix) }
        unreadable = unreadable.filter { $0 != key && !$0.hasPrefix(prefix) }
    }
}
