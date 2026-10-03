import Foundation

public struct FileNode: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isDirectory: Bool
    public var id: String { url.fileKey }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
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
                nodes.append(FileNode(url: directory.appending(path: url.lastPathComponent, directoryHint: isDirectory ? .isDirectory : .notDirectory), isDirectory: isDirectory))
            }
        }
        return nodes.sorted(by: precedes)
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
    @discardableResult
    public mutating func addRoot(_ url: URL) -> Bool {
        guard !roots.contains(where: { $0.fileKey == url.fileKey }) else { return false }
        roots.append(url)
        setExpanded(url, true)
        return true
    }

    public mutating func removeRoot(_ url: URL) {
        roots.removeAll { $0.fileKey == url.fileKey }
        drop(url.fileKey)
    }

    // MARK: Loading

    /// The loaded listing of `directory`; nil when it has not been read yet.
    public func children(of directory: URL) -> [FileNode]? { listings[directory.fileKey] }

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

    public mutating func setOptions(_ new: FileTreeOptions) {
        guard new != options else { return }
        options = new
        for key in Array(listings.keys) { relist(URL(fileURLWithPath: key, isDirectory: true)) }
    }

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

    public mutating func setExpanded(_ directory: URL, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(directory.fileKey)
            loadChildren(of: directory)
        } else {
            expanded.remove(directory.fileKey)
        }
    }

    // MARK: Flattened view

    /// Visible rows in display order, roots first. Only expanded directories contribute their children.
    public func rows() -> [Row] {
        var out: [Row] = []
        func walk(_ node: FileNode, depth: Int) {
            let open = node.isDirectory && expanded.contains(node.id)
            out.append(Row(node: node, depth: depth, isExpanded: open))
            if open { for child in listings[node.id] ?? [] { walk(child, depth: depth + 1) } }
        }
        for root in roots { walk(FileNode(url: root, isDirectory: true), depth: 0) }
        return out
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
