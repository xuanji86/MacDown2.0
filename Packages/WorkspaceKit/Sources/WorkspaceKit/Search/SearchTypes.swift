import Foundation

/// What to look for (PLAN 4.12). Plain mode: whitespace-separated words that must all be on the same line, `"exact
/// phrase"`, `-word` / `-"phrase"` to leave out lines containing it; case, accents and full/half-width forms are ignored.
/// Regex mode: the whole text is one regular expression (case-insensitive), nothing else is parsed.
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var isRegex: Bool
    /// Which files are looked at: the sidebar's rules (ignored folders, Markdown family or every file).
    public var files: FileTreeOptions
    /// Most hits returned (one per matching line).
    public var limit: Int

    // lazy: 1,000 hits, then the stream ends with `SearchError.truncated`; upgrade: paging in the results list
    public static let defaultLimit = 1000

    public init(text: String, isRegex: Bool = false, files: FileTreeOptions = FileTreeOptions(), limit: Int = SearchQuery.defaultLimit) {
        self.text = text
        self.isRegex = isRegex
        self.files = files
        self.limit = limit
    }

    /// Nothing to search for (blank, or only `-exclusions`): the UI does not start a search.
    public var isBlank: Bool {
        if isRegex { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return TermParser.parse(text).include.isEmpty
    }
}

/// One matching line. A provider that cannot say where in the file (a semantic one) leaves `line` nil.
public struct SearchHit: Sendable, Equatable, Identifiable {
    /// The provider that found it (`SearchProvider.id`): the badge on the result.
    public let source: String
    public let file: URL
    /// 1-based, as the editor's line numbers; the editor sees LF-normalised text, so CR and CRLF count as one break.
    public let line: Int?
    /// UTF-16 columns of the first match within the whole line (what the editor selects).
    public let columns: Range<Int>?
    /// The line, shortened around the first match when it is long.
    public let snippet: String
    /// UTF-16 ranges inside `snippet` to emphasise.
    public let highlights: [Range<Int>]

    public var id: String { "\(source)|\(file.fileKey)|\(line ?? 0)" }

    public init(source: String, file: URL, line: Int?, columns: Range<Int>?, snippet: String, highlights: [Range<Int>]) {
        self.source = source
        self.file = file
        self.line = line
        self.columns = columns
        self.snippet = snippet
        self.highlights = highlights
    }
}

/// How a search stream can end other than normally. `truncated` still comes after every hit that was found.
public enum SearchError: Error, Equatable, LocalizedError {
    public enum Limit: Sendable, Equatable {
        case hits(Int)
        case files(Int)
    }

    case invalidRegex
    case truncated(Limit)

    public var errorDescription: String? {
        switch self {
        case .invalidRegex: return "正则表达式无效"
        case .truncated(.hits(let n)): return "只显示前 \(n) 处匹配，请缩小范围"
        case .truncated(.files(let n)): return "只搜索了前 \(n) 个文件，请缩小范围"
        }
    }
}

// MARK: Parsing

enum TermParser {
    /// Words and phrases from `text`. A quote that is never closed takes the rest of the text (the query is being typed).
    /// A lone `-` is a word, not an exclusion of nothing.
    static func parse(_ text: String) -> (include: [String], exclude: [String]) {
        var include: [String] = [], exclude: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negative = false
            if chars[i] == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                negative = true
                i += 1
            }
            var term = ""
            if opening.contains(chars[i]) {
                i += 1
                while i < chars.count, !closing.contains(chars[i]) { term.append(chars[i]); i += 1 }
                i += 1  // the closing quote
            } else {
                while i < chars.count, !chars[i].isWhitespace { term.append(chars[i]); i += 1 }
            }
            if term.isEmpty { continue }
            if negative { exclude.append(term) } else { include.append(term) }
        }
        return (include, exclude)
    }

    private static let opening: Set<Character> = ["\"", "\u{201C}"]
    private static let closing: Set<Character> = ["\"", "\u{201D}"]
}

// MARK: Matching

struct LineMatch: Equatable {
    /// UTF-16 ranges inside the line, sorted, overlaps merged.
    let ranges: [Range<Int>]
}

/// Decides whether a line matches. `include` terms must all occur, `exclude` terms must not; nothing is assumed about word
/// boundaries, so Chinese, Japanese and Korean match like any other text.
struct SearchMatcher: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe
    private enum Kind {
        case terms(include: [String], exclude: [String])
        case regex(NSRegularExpression)
    }

    private let kind: Kind
    private static let compare: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    // lazy: 50 highlights per line; the snippet only has room for a few
    private static let maxRanges = 50

    init(_ query: SearchQuery) throws {
        if query.isRegex {
            do {
                // lazy: regex mode is case-insensitive but not accent-insensitive (ICU has no such flag); upgrade: fold both sides
                kind = .regex(try NSRegularExpression(pattern: query.text, options: [.caseInsensitive]))
            } catch {
                throw SearchError.invalidRegex
            }
        } else {
            let parsed = TermParser.parse(query.text)
            kind = .terms(include: parsed.include, exclude: parsed.exclude)
        }
    }

    /// Terms every matching file must contain somewhere (the quick reject before splitting a file into lines).
    /// Empty for regex mode, where no such shortcut is safe.
    var requiredTerms: [String] {
        if case .terms(let include, _) = kind { return include }
        return []
    }

    func fileMayMatch(_ text: NSString) -> Bool {
        requiredTerms.allSatisfy { text.range(of: $0, options: Self.compare).location != NSNotFound }
    }

    /// Matches within `line` (a range of `text`); the ranges returned are relative to the start of the line. All work is on
    /// `NSString` (UTF-16, so the offsets need no conversion): Swift's own `String.range(of:options:)` is ~15x slower.
    func match(in text: NSString, line: NSRange) -> LineMatch? {
        switch kind {
        case .terms(let include, let exclude):
            guard !include.isEmpty else { return nil }
            var found: [Range<Int>] = []
            for term in include {
                // Every required term has to be on the line; only the highlights are capped.
                var present = false
                var rest = line
                while rest.length > 0 {
                    let r = text.range(of: term, options: Self.compare, range: rest)
                    guard r.location != NSNotFound, r.length > 0 else { break }
                    present = true
                    if found.count >= Self.maxRanges { break }
                    found.append(r.location - line.location..<NSMaxRange(r) - line.location)
                    rest = NSRange(location: NSMaxRange(r), length: NSMaxRange(line) - NSMaxRange(r))
                }
                if !present { return nil }
            }
            for term in exclude where text.range(of: term, options: Self.compare, range: line).location != NSNotFound { return nil }
            return LineMatch(ranges: Self.merged(found))
        case .regex(let regex):
            // lazy: lines are matched whole; a pathological pattern on one huge line can be slow (cancellation is checked between lines)
            // The NSString-backed String is handed over as it is (no copy per line); the range's bounds anchor, so ^ and $
            // mean the line's ends.
            // lazy: a lookbehind / lookahead that spans a line break can still see the neighbouring line; upgrade: cut the line out (3x slower)
            let found = regex.matches(in: text as String, range: line)
                .map(\.range).filter { $0.length > 0 }.prefix(Self.maxRanges)
            guard !found.isEmpty else { return nil }
            return LineMatch(ranges: Self.merged(found.map { $0.location - line.location..<NSMaxRange($0) - line.location }))
        }
    }

    /// One line on its own (what the tests and the matcher's callers outside the walk use).
    func match(_ line: String) -> LineMatch? {
        let text = line as NSString
        return match(in: text, line: NSRange(location: 0, length: text.length))
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

// MARK: Snippets

enum SearchSnippet {
    // lazy: 120 UTF-16 units around the first match (a sidebar row shows two lines); upgrade: size to the sidebar width
    static let maxUnits = 120
    static let lead = 24

    /// `line` without its indentation, cut to a window around the first match when long ("…" marks what was left out),
    /// with `ranges` (UTF-16 inside `line`) translated into the snippet.
    static func make(line: String, ranges rawRanges: [Range<Int>]) -> (text: String, highlights: [Range<Int>]) {
        let ns = line as NSString
        let length = ns.length
        // Whatever the caller says, only ranges inside the line count: every offset below is then in 0...length.
        let ranges = rawRanges.filter { $0.lowerBound >= 0 && $0.lowerBound < $0.upperBound && $0.upperBound <= length }
        var start = 0, end = length
        while start < end, isBlank(ns.character(at: start)) { start += 1 }
        while end > start, isBlank(ns.character(at: end - 1)) { end -= 1 }
        // A match in the indentation or the trailing blanks (a regex like ` {2}$`) stays in the snippet.
        if let first = ranges.first { start = min(start, first.lowerBound) }
        if let last = ranges.map(\.upperBound).max() { end = max(end, last) }

        var from = start, to = end
        if to - from > maxUnits {
            from = max(start, (ranges.first?.lowerBound ?? start) - lead)
            if from > start, from < length { from = ns.rangeOfComposedCharacterSequence(at: from).location }
            to = min(end, from + maxUnits)
            if to < end, to > from { to = ns.rangeOfComposedCharacterSequence(at: to - 1).upperBound }
            to = min(max(to, from), length)
        }
        let prefix = from > start ? "…" : "", suffix = to < end ? "…" : ""
        let text = prefix + ns.substring(with: NSRange(location: from, length: to - from)) + suffix
        let shift = (prefix as NSString).length - from
        let marks = ranges.compactMap { r -> Range<Int>? in
            let lo = max(r.lowerBound, from), hi = min(r.upperBound, to)
            return lo < hi ? lo + shift..<hi + shift : nil
        }
        return (text, marks)
    }

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x3000
    }
}
