import CoreServices
import Foundation

/// FSEvents over one or more workspace roots. Reports the *directories whose listing changed* (what the tree needs
/// to re-read), coalesced into one batch per `debounce` window. Events inside ignored directories are dropped before
/// they reach the window, so a Quarto render writing `foo_files/` or a build filling `node_modules` stays silent.
///
/// Call `stop()` when done: the stream retains the watcher until then. `onChange` runs on the watcher's own queue, so
/// hop to the main actor there and never call `stop()` from inside it (it synchronises with that queue).
public final class FolderWatcher: @unchecked Sendable {
    struct Root: Sendable {
        let given: String  // path as the caller wrote it (the tree's key)
        let resolved: String  // realpath: FSEvents reports /private/var, never /var
    }

    struct Event: Sendable {
        let path: String
        let isDirectory: Bool
        /// FSEvents coalesced or dropped events below `path` (MustScanSubDirs / UserDropped / KernelDropped): whatever is
        /// cached for the whole subtree may be stale.
        var mustRescan = false
        /// The watched root, or an ancestor of it, was renamed, moved or deleted (needs `watchRoot`).
        var rootChanged = false
    }

    /// One coalesced delivery.
    public struct Batch: Sendable {
        /// Directories whose own listing may have changed (in the caller's spelling of the root).
        public var directories: Set<URL> = []
        /// Directories whose whole subtree must be read again, not just the listing (dropped events, a moved root).
        public var subtrees: Set<URL> = []
        /// A watched root, or an ancestor of it, moved or went away: the stream does not follow it, so start over.
        public var rootChanged = false
    }

    struct Analysis: Sendable {
        var directories: Set<String> = []
        var subtrees: Set<String> = []
        var rootChanged = false
    }

    private let roots: [Root]
    private let ignore: IgnoreRules
    private let debounce: TimeInterval
    private let ignoreSelf: Bool
    private let watchRoot: Bool
    private let onBatch: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "WorkspaceKit.FolderWatcher")
    // Confined to `queue`:
    private var stream: FSEventStreamRef?
    private var pending = Analysis()
    private var flushScheduled = false
    private var stopped = false

    /// - Parameter ignoreSelf: drop events caused by this process (PLAN 4.11: the app refreshes by hand after its own
    ///   saves and file operations).
    public convenience init(
        roots: [URL], ignore: IgnoreRules = .default, debounce: TimeInterval = 0.25, ignoreSelf: Bool = true,
        onChange: @escaping @Sendable (Set<URL>) -> Void
    ) {
        self.init(roots: roots, ignore: ignore, debounce: debounce, ignoreSelf: ignoreSelf, watchRoot: false) { onChange($0.directories) }
    }

    /// - Parameter watchRoot: also report when a root, or an ancestor of it, is renamed or deleted (`Batch.rootChanged`).
    public init(
        roots: [URL], ignore: IgnoreRules = .default, debounce: TimeInterval = 0.25, ignoreSelf: Bool = true, watchRoot: Bool,
        onBatch: @escaping @Sendable (Batch) -> Void
    ) {
        self.roots = roots.map { Root(given: $0.fileKey, resolved: Self.realPath($0.fileKey)) }
        self.ignore = ignore
        self.debounce = debounce
        self.ignoreSelf = ignoreSelf
        self.watchRoot = watchRoot
        self.onBatch = onBatch
    }

    /// `URL.resolvingSymlinksInPath` strips `/private` (it would turn the realpath back into `/var/...`), and FSEvents
    /// reports the real one, so ask the C library.
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    /// Returns false when the stream could not be created or started. Idempotent.
    @discardableResult
    public func start() -> Bool {
        queue.sync {
            if stream != nil { return true }
            guard !roots.isEmpty else { return false }
            stopped = false
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(self).toOpaque(), retain: nil,
                release: { Unmanaged<FolderWatcher>.fromOpaque($0!).release() }, copyDescription: nil)
            var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            if ignoreSelf { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf) }
            if watchRoot { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot) }
            let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let events = (0..<min(count, list.count)).map { i in Event.make(path: list[i], flags: eventFlags[i]) }
                watcher.receive(events)
            }
            let paths = roots.map(\.resolved) as CFArray
            guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
            else {
                Unmanaged<FolderWatcher>.fromOpaque(context.info!).release()  // the context's retain never happened
                return false
            }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                return false
            }
            stream = s
            return true
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            pending = Analysis()
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)  // releases the context's retain on self
            stream = nil
        }
    }

    // MARK: Coalescing (on `queue`)

    private func receive(_ events: [Event]) {
        let found = Self.analyze(events, roots: roots, ignore: ignore)
        guard !found.directories.isEmpty, !stopped else { return }
        pending.directories.formUnion(found.directories)
        pending.subtrees.formUnion(found.subtrees)
        pending.rootChanged = pending.rootChanged || found.rootChanged
        // A fixed window from the first event, not a trailing debounce: a stream that never goes quiet still delivers.
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + debounce) { [self] in
            flushScheduled = false
            guard !stopped, !pending.directories.isEmpty else { return }
            func urls(_ paths: Set<String>) -> Set<URL> { Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }) }
            let batch = Batch(directories: urls(pending.directories), subtrees: urls(pending.subtrees), rootChanged: pending.rootChanged)
            pending = Analysis()
            onBatch(batch)
        }
    }

    static func affectedDirectories(_ events: [Event], roots: [Root], ignore: IgnoreRules) -> Set<String> {
        analyze(events, roots: roots, ignore: ignore).directories
    }

    /// Maps raw events to the directories (in the caller's spelling of the root) whose listing may have changed:
    /// the parent of every item, plus the item itself when it is a directory. Ignored paths yield nothing. An event
    /// that says "something below here was missed" or "the root moved" also names the subtree to read again.
    static func analyze(_ events: [Event], roots: [Root], ignore: IgnoreRules) -> Analysis {
        func join(_ root: Root, _ parts: ArraySlice<String>) -> String {
            parts.isEmpty ? root.given : (root.given == "/" ? "" : root.given) + "/" + parts.joined(separator: "/")
        }
        var out = Analysis()
        for event in events {
            if event.rootChanged {
                // Names the root, or an ancestor of it (then every root below that ancestor is affected).
                let prefix = event.path == "/" ? "/" : event.path + "/"
                for root in roots where root.resolved == event.path || root.resolved.hasPrefix(prefix) {
                    out.directories.insert(root.given)
                    out.subtrees.insert(root.given)
                    out.rootChanged = true
                }
                continue
            }
            guard let root = roots.first(where: { event.path == $0.resolved || event.path.hasPrefix($0.resolved == "/" ? "/" : $0.resolved + "/") })
            else { continue }
            let tail = event.path.dropFirst(root.resolved.count)
            let parts = tail.split(separator: "/").map(String.init)[...]
            let isDirectory = event.isDirectory || event.mustRescan
            if ignore.ignores(components: Array(parts), lastIsDirectory: isDirectory) { continue }
            if parts.isEmpty || isDirectory { out.directories.insert(join(root, parts)) }
            if !parts.isEmpty { out.directories.insert(join(root, parts.dropLast())) }
            if event.mustRescan { out.subtrees.insert(join(root, parts)) }
        }
        return out
    }
}

extension FolderWatcher.Event {
    static func make(path: String, flags: FSEventStreamEventFlags) -> Self {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        return Self(
            path: path, isDirectory: has(kFSEventStreamEventFlagItemIsDir),
            mustRescan: has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped),
            rootChanged: has(kFSEventStreamEventFlagRootChanged))
    }
}
