import Foundation

/// `QuartoIncludes.fileReader` with a memory, for the preview: it renders after every typing burst, and without this each render
/// reads up to 64 include files again on the main thread. A file is read again only when its size or date changed, and `changed`
/// tells a folder-change event whether a file the last render read (or looked for and did not find) is different now.
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
    }

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
        guard let directory else { return nil }
        // The stamp is taken before the read, so a change in between shows up as one. A symlink is stamped as its target.
        let url: URL
        if case .file(let file) = DocumentFileResolver.resolve(path: "/" + path, root: directory) { url = file } else { url = directory.appending(path: path) }
        let stamp = Stamp(url)
        if let entry = entries[path], entry.url == url, entry.stamp == stamp { return entry.text }
        let text = readFile(path)
        entries[path] = Entry(url: url, stamp: stamp, text: text)
        return text
    }

    /// A render is done: what it did not ask for (an include that was taken out of the text) is forgotten, so it cannot keep
    /// reporting changes.
    public func endRender() {
        entries = entries.filter { asked.contains($0.key) }
        asked = []
    }

    /// Whether any file the last render asked for differs now from what it read (changed, gone, or there where it was missing).
    public func changed() -> Bool {
        entries.values.contains { Stamp($0.url) != $0.stamp }
    }
}
