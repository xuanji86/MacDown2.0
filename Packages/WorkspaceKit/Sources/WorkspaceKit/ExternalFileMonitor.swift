import Foundation

/// Watches one open file for changes made by anyone else (CLI tools, `git checkout`, `sed -i`, AI agents, editors that
/// save by rename-replace; coordinated writes too) and turns them into `ExternalChangeTracker` actions.
///
/// How: one `FolderWatcher` on the file's directory (FSEvents sees uncoordinated writes, which `NSFilePresenter` never
/// does), events settled by a trailing debounce, then the file is read and compared by content, not by event. So the
/// system's own presenter reloading the same change first, or our own save, make this a no-op rather than a second reload.
/// The watcher also watches the directory below the file (FSEvents is recursive), which is how the preview learns that an
/// image it shows changed (`onSettled`).
///
/// Not attached to files on non-local volumes (SMB, AFP, NFS, WebDAV): FSEvents does not see other machines' writes
/// there, so a watcher would only look reliable. Such a document is simply not reloaded (`isWatchable`).
@MainActor
public final class ExternalFileMonitor {
    public let url: URL
    public private(set) var tracker: ExternalChangeTracker
    /// While true (the document is saving) events do not lead to a probe; `check()` afterwards catches up.
    public var isPaused = false
    private let isDirty: @MainActor () -> Bool
    private let onAction: @MainActor (ExternalChangeTracker.Action) -> Void
    private let onSettled: @MainActor () -> Void
    private let debouncer: Debouncer
    private let settle: Duration
    private let ignoreSelf: Bool
    private var watcher: FolderWatcher?

    /// - Parameters:
    ///   - synced: what the document holds of this file already (nil = adopt whatever is on disk at the first event).
    ///   - ignoreSelf: drop the events of this process's own writes (the document's saves; the content check would catch them
    ///     anyway). Tests write from the same process, so they turn it off.
    ///   - isDirty: the user has unsaved edits.
    ///   - onAction: what to do about a change; runs on the main actor, at most once per distinct
    ///     change; `.none` when only `tracker.isPrompting` / `isMissing` changed.
    ///   - onSettled: a burst of events in the file's directory is over (after `onAction`, if it had one).
    public init(
        url: URL, synced: ExternalChangeTracker.Disk?, settle: Duration = .milliseconds(300), ignoreSelf: Bool = true,
        isDirty: @escaping @MainActor () -> Bool, onAction: @escaping @MainActor (ExternalChangeTracker.Action) -> Void,
        onSettled: @escaping @MainActor () -> Void = {}
    ) {
        self.url = url
        self.settle = settle
        self.ignoreSelf = ignoreSelf
        tracker = ExternalChangeTracker(synced: synced)
        self.isDirty = isDirty
        self.onAction = onAction
        self.onSettled = onSettled
        debouncer = Debouncer(delay: settle)
    }

    /// Local volumes only; a file we cannot ask about (nil) is not watched either.
    public static func isWatchable(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]) else { return false }
        return values.volumeIsLocal == true
    }

    /// False when the file is not watchable or the stream could not start. Idempotent.
    @discardableResult
    public func start() -> Bool {
        if watcher != nil { return true }
        let directory = url.deletingLastPathComponent()
        guard Self.isWatchable(directory) else { return false }
        let key = directory.fileKey
        // Quarto's `*_files` output is not ignored here: an image the preview shows may live in one. `.git` and
        // `node_modules` only ever cost wake-ups.
        let ignore = IgnoreRules(names: [".git", "node_modules"], suffixes: [])
        let watcher = FolderWatcher(roots: [directory], ignore: ignore, debounce: 0.1, ignoreSelf: ignoreSelf) { [weak self] batch in
            // Only batches that touch the file's own directory or below can concern the file (the file's directory is
            // reported for every change of one of its entries, and for a sub-directory that changed).
            guard batch.contains(where: { $0.fileKey == key || $0.fileKey.hasPrefix(key + "/") }) else { return }
            Task { @MainActor in self?.eventsArrived() }
        }
        guard watcher.start() else { return false }
        self.watcher = watcher
        return true
    }

    /// Stops watching; nothing is delivered afterwards.
    public func stop() {
        debouncer.cancel()
        watcher?.stop()
        watcher = nil
    }

    // MARK: Document side

    /// The document read the file, or saved to it: this is what the text corresponds to now.
    public func didSync(_ disk: ExternalChangeTracker.Disk) { tracker.didSync(disk) }

    /// The user chose to keep their text over what is on disk now.
    public func keepMine() {
        guard tracker.isPrompting else { return }
        switch Self.readDisk(url) {
        case .present(let fingerprint): tracker.keepMine(acknowledging: .present(fingerprint))
        case .missing: probe(.missing, isDirty: true)
        case .unreadable: tracker.promptNotShown()
        }
    }

    public func promptNotShown() { tracker.promptNotShown() }

    // MARK: Probing

    /// Reads the file now and decides (also what a settled burst of events does).
    public func check() {
        guard !isPaused, watcher != nil else { return }
        switch Self.readDisk(url) {
        case .present(let fingerprint): probe(.present(fingerprint), isDirty: isDirty())
        case .missing: probe(.missing, isDirty: isDirty())
        case .unreadable: break  // a transient error (permissions mid-replace): the next event asks again
        }
    }

    private func eventsArrived() {
        guard watcher != nil else { return }
        debouncer.submit { [weak self] in
            guard let self, watcher != nil else { return }
            check()
            onSettled()
        }
    }

    /// `.none` can still end a prompt (the file went back to what we have) or clear the missing mark (it came back unchanged):
    /// the document is told about every change of that state, with `.none`, so what shows it can follow.
    private func probe(_ disk: ExternalChangeTracker.Disk, isDirty: Bool) {
        let (wasMissing, wasPrompting) = (tracker.isMissing, tracker.isPrompting)
        let action = tracker.probe(disk, isDirty: isDirty)
        if action != .none || tracker.isMissing != wasMissing || tracker.isPrompting != wasPrompting { onAction(action) }
    }

    enum DiskRead {
        case present(FileFingerprint)
        case missing
        case unreadable
    }

    // lazy: reads and hashes the whole file per settled burst of events in its directory; fine for Markdown. Upgrade
    // path: compare size + modification date first and read only when they differ.
    static func readDisk(_ url: URL) -> DiskRead {
        do {
            let data = try Data(contentsOf: url)
            return .present(FileFingerprint(data))
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
    }
}
