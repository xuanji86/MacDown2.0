import Foundation
import Synchronization

/// The core full-text search (PLAN 4.12): walks a workspace folder in the sidebar tree's order, reads every text file
/// the tree would show and matches line by line. Always available, needs nothing installed. `ExtensionAPI` makes it a
/// `SearchProvider`.
///
/// Each search runs on its own background task and streams hits as they are found; ending the stream (or `cancel()`) stops
/// the walk at the next file or the next few hundred lines.
public final class BuiltinSearchBackend: Sendable {
    public static let providerID = "builtin"

    private let maxFileBytes: Int
    private let maxFiles: Int
    private let running = Mutex<[UUID: Task<Void, Never>]>([:])

    // lazy: files over 5 MB are skipped and a search stops after 20,000 text files (SearchError.truncated); upgrade: an on-disk index (the optional qmd provider)
    public init(maxFileBytes: Int = 5_000_000, maxFiles: Int = 20_000) {
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    /// Hits in tree order (folders first, Finder-style natural order), a file's hits in line order. The stream finishes
    /// normally, or with a `SearchError` (`invalidRegex` before any hit; `truncated` after the last one).
    public func search(_ query: SearchQuery, in workspace: URL) -> AsyncThrowingStream<SearchHit, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            let (maxFileBytes, maxFiles) = (maxFileBytes, maxFiles)
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let matcher = try SearchMatcher(query)
                    var walk = Walk(
                        query: query, matcher: matcher, maxFileBytes: maxFileBytes, maxFiles: maxFiles,
                        emit: { continuation.yield($0) })
                    walk.visit(workspace, depth: 0)
                    if let limit = walk.stoppedBy { continuation.finish(throwing: SearchError.truncated(limit)) } else { continuation.finish() }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            running.withLock { $0[id] = task }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.running.withLock { $0[id] = nil }
            }
        }
    }

    /// Stops every search in flight (their streams finish without further hits).
    public func cancel() {
        let tasks = running.withLock { Array($0.values) }
        for task in tasks { task.cancel() }
    }
}

private struct Walk {
    let query: SearchQuery
    let matcher: SearchMatcher
    let maxFileBytes: Int
    let maxFiles: Int
    let emit: (SearchHit) -> Void

    private(set) var stoppedBy: SearchError.Limit?
    private var finished = false
    private var hits = 0
    private var files = 0
    private var seen = Set<String>()

    init(query: SearchQuery, matcher: SearchMatcher, maxFileBytes: Int, maxFiles: Int, emit: @escaping (SearchHit) -> Void) {
        self.query = query
        self.matcher = matcher
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.emit = emit
    }

    // lazy: 40 levels deep; real paths are tracked, so a symlink loop is read once
    private static let maxDepth = 40

    mutating func visit(_ directory: URL, depth: Int) {
        guard !finished, depth <= Self.maxDepth, !Task.isCancelled else { return }
        guard seen.insert(directory.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { return }
        // Same listing as the sidebar tree: its ignore rules, "show all files", packages as files, links to folders as folders.
        guard let nodes = try? DirectoryLister.list(directory, options: query.files) else { return }
        for node in nodes where !finished {
            if Task.isCancelled { finished = true; return }
            if node.isDirectory { visit(node.url, depth: depth + 1) } else { scan(node.url) }
        }
    }

    private mutating func scan(_ url: URL) {
        guard let text = Self.read(url, maxBytes: maxFileBytes) else { return }
        files += 1
        if files > maxFiles { stop(.files(maxFiles)); return }
        guard matcher.fileMayMatch(text) else { return }

        for (index, range) in Self.lineRanges(of: text).enumerated() {
            if index & 0x1FF == 0x1FF, Task.isCancelled { finished = true; return }
            guard let match = matcher.match(in: text, line: range) else { continue }
            if hits >= query.limit { stop(.hits(query.limit)); return }
            hits += 1
            let snippet = SearchSnippet.make(line: text.substring(with: range), ranges: match.ranges)
            emit(SearchHit(
                source: BuiltinSearchBackend.providerID, file: url, line: index + 1, columns: match.ranges.first,
                snippet: snippet.text, highlights: snippet.highlights))
        }
    }

    private mutating func stop(_ limit: SearchError.Limit) {
        stoppedBy = limit
        finished = true
    }

    /// The text as UTF-16, or nil when the file is too big, empty, binary or not UTF-8. A UTF-8 BOM is dropped, as the editor does.
    // lazy: UTF-8 only, so a file the editor would open as UTF-16 or a legacy encoding is not searched; upgrade: MarkdownFile.decode
    private static func read(_ url: URL, maxBytes: Int) -> NSString? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxBytes, !data.prefix(8192).contains(0)
        else { return nil }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return NSString(data: Data(body), encoding: String.Encoding.utf8.rawValue)
    }

    /// The lines of `text` without their terminators. CR, LF and CRLF are one break each: what the editor does when it loads
    /// the file, so line numbers agree. An empty line after the last terminator is not a line.
    static func lineRanges(of text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var buffer = [unichar](repeating: 0, count: 4096)
        let length = text.length
        var start = 0, index = 0, afterCR = -1
        while index < length {
            let n = min(buffer.count, length - index)
            text.getCharacters(&buffer, range: NSRange(location: index, length: n))
            for k in 0..<n {
                let unit = buffer[k], position = index + k
                if unit == 0x0A {
                    if position == afterCR { start = position + 1; continue }  // the LF of a CRLF
                    out.append(NSRange(location: start, length: position - start))
                    start = position + 1
                } else if unit == 0x0D {
                    out.append(NSRange(location: start, length: position - start))
                    start = position + 1
                    afterCR = position + 1
                }
            }
            index += n
        }
        if start < length { out.append(NSRange(location: start, length: length - start)) }
        return out
    }
}
