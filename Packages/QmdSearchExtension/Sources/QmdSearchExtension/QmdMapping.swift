import Foundation
import WorkspaceKit

/// Pure decisions about collections and results (all unit-tested).
enum QmdMapping {
    static let ownPrefix = "macdown2-"
    /// `.qmd` is not in qmd's default mask (`**/*.md`), so it is always given.
    static let mask = "**/*.{md,markdown,qmd}"

    /// The collection to search `realRoot` with: one whose folder is the root or contains it, ours (`macdown2-…`) for exactly
    /// this folder first, else the closest folder (a user's `~/notes` serves `~/notes/book`). nil = none covers it.
    // lazy: coverage is by folder only, a user collection whose mask leaves out .qmd/.markdown still counts; upgrade: match masks too
    static func covering(_ collections: [QmdCollection], realRoot: String) -> QmdCollection? {
        let candidates = collections.map { (collection: $0, folder: realPath($0.path)) }.filter { realRoot.isPath(atOrUnder: $0.folder) }
        if let own = candidates.first(where: { $0.collection.name.hasPrefix(ownPrefix) && $0.folder == realRoot }) { return own.collection }
        return candidates.max { $0.folder.count < $1.folder.count }?.collection
    }

    /// `macdown2-<slug>-<hash>`: the folder's name in lowercase ASCII (other characters become "-") and 8 hex digits of its
    /// full path, so two folders called "notes" get different collections and the same folder always gets the same one.
    static func collectionName(forRealRoot realRoot: String) -> String {
        let name = (realRoot as NSString).lastPathComponent.lowercased()
        var slug = ""
        for scalar in name.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(32))
        while slug.hasSuffix("-") { slug.removeLast() }
        let hash = String(format: "%08x", fnv1a(realRoot))
        return ownPrefix + (slug.isEmpty ? hash : slug + "-" + hash)
    }

    private static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// One qmd result as a search hit in `workspace` (as the caller spells it), or nil when the file is gone (`qmd://…`) or
    /// outside the workspace (a collection that covers a parent folder also finds files next to it).
    /// `terms`: `terms(of:)` of the query.
    static func hit(_ result: QmdParse.Result, workspace: URL, realRoot: String, terms: [String], source: String) -> SearchHit? {
        var path = result.file
        if path.hasPrefix("./") { path = QmdRunner.workingDirectory + path.dropFirst(2) }
        // Compared as qmd printed it (a realpath): `standardizingPath` would drop the `/private` of an existing `/private/var/…`.
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.isPath(atOrUnder: realRoot) else { return nil }
        var base = workspace.path(percentEncoded: false)
        if base.count > 1, base.hasSuffix("/") { base.removeLast() }
        let file = URL(filePath: base + path.dropFirst(realRoot.count), directoryHint: .notDirectory)
        let line = result.line.flatMap { $0 > 0 ? $0 : nil }
        let raw = line.flatMap { l in result.snippet.flatMap { QmdParse.snippetLine($0, line: l) } }
            ?? result.snippet.flatMap(firstTextLine) ?? result.title ?? ""
        let (snippet, highlights) = shorten(raw.trimmingCharacters(in: .whitespaces), terms: terms)
        return SearchHit(source: source, file: file, line: line, columns: nil, snippet: snippet, highlights: highlights)
    }

    private static func firstTextLine(_ snippet: String) -> String? {
        snippet.components(separatedBy: "\n").dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The words of a query to highlight: quotes dropped, `-excluded` words left out.
    static func terms(of query: String) -> [String] {
        var out: [String] = []
        for phrase in query.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
            if phrase.offset % 2 == 1 {
                let text = phrase.element.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(text) }
                continue
            }
            for word in phrase.element.split(whereSeparator: \.isWhitespace) where !word.hasPrefix("-") {
                out.append(String(word))
            }
        }
        return out
    }

    // lazy: 160 UTF-16 units around the first highlight (a sidebar row shows two lines); the core's snippet maker is internal to WorkspaceKit
    static let maxSnippet = 160

    /// `line` cut to `maxSnippet` around the first term found, with every occurrence of the terms marked (UTF-16 ranges).
    static func shorten(_ line: String, terms: [String]) -> (String, [Range<Int>]) {
        var text = line as NSString
        func find(_ text: NSString) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            for term in terms {
                var from = 0
                while from < text.length {
                    let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: NSRange(location: from, length: text.length - from))
                    guard r.location != NSNotFound, r.length > 0 else { break }
                    ranges.append(r.location..<NSMaxRange(r))
                    from = NSMaxRange(r)
                }
            }
            return ranges.sorted { $0.lowerBound < $1.lowerBound }
        }
        if text.length > maxSnippet {
            let first = find(text).first?.lowerBound ?? 0
            var from = max(0, first - 24)
            if from > 0 { from = text.rangeOfComposedCharacterSequence(at: from).location }
            var to = min(text.length, from + maxSnippet)
            if to < text.length { to = NSMaxRange(text.rangeOfComposedCharacterSequence(at: to - 1)) }
            text = ((from > 0 ? "…" : "") + text.substring(with: NSRange(location: from, length: to - from)) + (to < text.length ? "…" : "")) as NSString
        }
        // Overlapping matches (two terms in one word) are merged, as the core does.
        var merged: [Range<Int>] = []
        for r in find(text) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return (text as String, merged)
    }
}
