import Foundation

/// `QuartoIncludes.fileReader` with a memory, for the preview: it renders after every typing burst, and without this each render
/// reads up to 64 include files again on the main thread. A file is read again only when its size or date changed, and `changed`
/// tells a folder-change event whether a file the last render read (or looked for and did not find) is different now. Within
/// `recheckInterval` of a file's last check, `read` does not look at the disk at all (typing renders can come every ~50 ms);
/// `changed` finding a difference makes every file due for a check at once, so the render it triggers sees the new text.
/// Not thread-safe: one owner, one thread.
public final class IncludeFileCache {
    private struct Stamp: Equatable {
        var size: Int?
        var modified: Date?
        /// `attributesOfItem`, not `URL.resourceValues`: a `URL` object caches what it returned, so a second stamp of the same value
        /// would not see an overwrite. A missing file has neither.
        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes?[.size] as? NSNumber)?.intValue
            modified = attributes?[.modificationDate] as? Date
        }
    }
    private struct Entry {
        var url: URL
        var stamp: Stamp
        var text: String?
        var checked: ContinuousClock.Instant
    }
    // lazy: an include changed on disk is picked up up to 500 ms late by a render (the folder watcher's `changed` is not delayed), upgrade: a per-file event source.
    private static let recheckInterval = Duration.milliseconds(500)

    private let directory: URL?
    private let readFile: (String) -> String?
    private var entries: [String: Entry] = [:]
    private var asked: Set<String> = []

    public init(directory: URL?) {
        self.directory = directory
        readFile = QuartoIncludes.fileReader(directory: directory)
    }

    /// The reader for `QuartoIncludes.files(for:readFile:)` (same rules as `QuartoIncludes.fileReader`); `endRender()` afterwards.
    public func read(_ path: String) -> String? {
        asked.insert(path)
        let now = ContinuousClock.now
        if let entry = entries[path], now - entry.checked < Self.recheckInterval { return entry.text }
        guard let url = locate(path) else { return nil }
        // The stamp is taken before the read, so a change in between shows up as one.
        let stamp = Stamp(url)
        if let entry = entries[path], entry.url == url, entry.stamp == stamp {
            entries[path]?.checked = now
            return entry.text
        }
        let text = readFile(path)
        entries[path] = Entry(url: url, stamp: stamp, text: text, checked: now)
        return text
    }

    /// The file `path` is, now: what it resolves to (a symlink is its target), or where it would be if it is missing.
    private func locate(_ path: String) -> URL? {
        guard let directory else { return nil }
        if case .file(let file) = DocumentFileResolver.resolve(path: "/" + path, root: directory) { return file }
        return directory.appending(path: path)
    }

    /// A render is done: what it did not ask for (an include that was taken out of the text) is forgotten, so it cannot keep
    /// reporting changes.
    public func endRender() {
        entries = entries.filter { asked.contains($0.key) }
        asked = []
    }

    /// Whether any file the last render asked for differs now from what it read (changed, gone, or there where it was missing).
    /// Each path is resolved again, as `read` does: a symlink pointed elsewhere or removed is a change although its old target is not.
    public func changed() -> Bool {
        let different = entries.contains { locate($0.key) != $0.value.url || Stamp($0.value.url) != $0.value.stamp }
        if different { for key in entries.keys { entries[key]?.checked = ContinuousClock.now - Self.recheckInterval } }
        return different
    }
}
