import Foundation
import Neon
import SwiftTreeSitter
import TreeSitterClient

public struct HighlightToken: Equatable, Sendable {
    public var kind: TokenKind
    public var range: NSRange
    public init(kind: TokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public typealias HighlightExecutionMode = TreeSitterClient.ExecutionMode

public enum HighlightError: Error {
    case staleContent
    case markedText
}

/// tree-sitter side of the editor: block tree kept incrementally by Neon's `TreeSitterClient`, inline grammar run
/// on demand over the inline nodes the block tree reports. No AppKit; the owner feeds it the text.
@MainActor
public final class MarkdownHighlightEngine {
    /// Substring of the current text (UTF-16 range). Set by the owner; used for inline parsing.
    public var textProvider: (NSRange) -> String? = { _ in nil }

    /// Inline nodes longer than this are left unstyled (one giant paragraph would be re-parsed for every chunk request).
    // lazy: 64K UTF-16 units per inline node, cache the inline tree per node (keyed by block-tree version) when it hurts
    static let maxInlineLength = 65_536

    /// Queries and edits up to this many UTF-16 units run synchronously on the main thread when no parse is in flight;
    /// larger ones go to Neon's background queue. Also the chunk size Neon's `Highlighter` requests, and it must stay
    /// small: that class walks every integer of the expanded visible range per scheduling step.
    static let synchronousLimit = 1024

    /// A fenced block or front matter longer than this keeps the plain code colour instead of its language's.
    // lazy: 64K UTF-16 units per region, parsed whole on each edit; upgrade = Parser.parse(oldTree) with the edit applied (incremental) if long scripts matter
    static let maxInjectionLength = 65_536

    private let client: TreeSitterClient
    private let inlineParser = Parser()
    private var injectionParsers: [InjectedLanguage: Parser] = [:]
    /// The last few regions' tokens (relative to the region): every chunk of a long block asks again. Keyed by where the region is
    /// and `contentVersion`, which any edit bumps, so a hit costs no copy of the region's text.
    private var injectionCache: [(key: InjectionKey, tokens: [HighlightToken])] = []
    private struct InjectionKey: Hashable {
        var language: InjectedLanguage
        var range: NSRange
        var version: Int
    }
    private static let injectionCacheSize = 8
    private var contentVersion = 0

    /// Where the injected regions (fenced code, front matter) are, as the last token passes saw them and edits have moved them since.
    /// The owner uses them to restyle a whole region when an edit inside it, or on its fence line, changes how all of it parses.
    private(set) var injectionRegions: [InjectionRegion] = []

    /// - Parameter pointForOffset: UTF-16 offset -> (row, column in bytes). tree-sitter-markdown's scanner depends on
    ///   columns, so incremental edits must carry real points rather than zeros.
    public init(pointForOffset: @escaping (Int) -> Point?) throws {
        client = try TreeSitterClient(language: Grammar.block, transformer: pointForOffset, synchronousLengthThreshold: Self.synchronousLimit)
        try inlineParser.setLanguage(Grammar.inline)
    }

    /// Set while the owner is typing; ranges the edit made invalid (already shifted to current coordinates).
    public var invalidationHandler: (IndexSet) -> Void {
        get { client.invalidationHandler }
        set { client.invalidationHandler = newValue }
    }

    public func willChangeContent(in range: NSRange) { client.willChangeContent(in: range) }

    /// Moves the remembered regions through an edit (`range` in the old text, `delta` the change in length): a region the edit
    /// overlaps grows or shrinks with it.
    private func noteEdit(in range: NSRange, delta: Int) {
        contentVersion += 1
        injectionRegions = injectionRegions.map { region in
            var r = region.range
            if NSMaxRange(r) <= range.location { return region }
            if r.location >= NSMaxRange(range) { r.location += delta } else { r.length = max(0, r.length + delta) }
            return InjectionRegion(language: region.language, range: r)
        }
    }

    /// `range`/`delta` are the pre-edit range and the length change, as in Neon (`NSTextStorage` `editedRange` with
    /// `changeInLength` already subtracted). `snapshot` must be immutable: Neon may parse it on a background queue.
    public func didChangeContent(to snapshot: NSString, in range: NSRange, delta: Int, completion: @escaping () -> Void = {}) {
        noteEdit(in: range, delta: delta)
        client.didChangeContent(in: range, delta: delta, limit: snapshot.length, readHandler: Self.reader(for: snapshot), completionHandler: completion)
    }

    /// Feeds tree-sitter UTF-16 straight from the snapshot (no transcoding to UTF-8, which cost ~15 ms per keystroke at 1 MB).
    nonisolated static func reader(for snapshot: NSString) -> Parser.ReadBlock {
        { byteOffset, _ in
            let start = byteOffset / 2
            guard start < snapshot.length else { return nil }
            let count = min(4096, snapshot.length - start)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes {
                snapshot.getCharacters($0.baseAddress!.assumingMemoryBound(to: unichar.self), range: NSRange(location: start, length: count))
            }
            return data
        }
    }

    /// Tokens for `range`, outer constructs before inner ones, block tokens before inline ones, all clipped to `range`.
    public func tokens(
        in range: NSRange,
        mode: HighlightExecutionMode = .synchronousPreferred,
        completion: @escaping (Result<[HighlightToken], Error>) -> Void
    ) {
        client.executeResolvingQuery(Grammar.blockQuery, in: range, executionMode: mode) { [self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let cursor): completion(.success(collect(from: cursor, in: range)))
            }
        }
    }

    private func collect(from cursor: ResolvingQueryCursor, in range: NSRange) -> [HighlightToken] {
        var block: [HighlightToken] = []
        var inlineNodes: [NSRange] = []
        var regions: [InjectionRegion] = []
        for match in cursor {
            var info: NSRange?, content: NSRange?
            for capture in match.captures {
                guard let name = capture.name else { continue }
                if name == Grammar.inlineCapture {
                    inlineNodes.append(capture.range)
                } else if name == Grammar.injectYAMLCapture {
                    if capture.range.length <= Self.maxInjectionLength, let text = textProvider(capture.range),
                       let yaml = InjectedLanguage.yamlRange(ofFrontMatter: text as NSString) {
                        regions.append(InjectionRegion(language: .yaml, range: NSRange(location: capture.range.location + yaml.location, length: yaml.length)))
                    }
                } else if name == Grammar.injectInfoCapture {
                    info = capture.range
                } else if name == Grammar.injectContentCapture {
                    content = capture.range
                } else if let kind = TokenKind(rawValue: name), let clipped = Self.clip(capture.range, to: range) {
                    block.append(HighlightToken(kind: kind, range: clipped))
                }
            }
            if let info, let content, content.length <= Self.maxInjectionLength, let text = textProvider(info),
               let language = InjectedLanguage.named(infoString: text) {
                regions.append(InjectionRegion(language: language, range: content))
            }
        }
        // The chunk's regions replace what was remembered for it.
        injectionRegions.removeAll { NSIntersectionRange($0.range, range).length > 0 || regions.contains($0) }
        injectionRegions += regions
        return Self.outerFirst(block) + inlineTokens(for: inlineNodes, clippedTo: range) + injectionTokens(for: regions, clippedTo: range)
    }

    /// The tokens of the code inside fences and front matter, after everything else so the language's colours win over `codeBlock`.
    private func injectionTokens(for regions: [InjectionRegion], clippedTo range: NSRange) -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        var seen = Set<Int>()
        for region in regions where NSIntersectionRange(region.range, range).length > 0 && seen.insert(region.range.location).inserted {
            for token in injectedTokens(region) {
                let shifted = NSRange(location: token.range.location + region.range.location, length: token.range.length)
                if let clipped = Self.clip(shifted, to: range) { tokens.append(HighlightToken(kind: token.kind, range: clipped)) }
            }
        }
        return tokens
    }

    /// Tokens of the region parsed as its language, relative to its start, outer ones first.
    private func injectedTokens(_ region: InjectionRegion) -> [HighlightToken] {
        let language = region.language
        let key = InjectionKey(language: language, range: region.range, version: contentVersion)
        if let hit = injectionCache.firstIndex(where: { $0.key == key }) {
            let entry = injectionCache.remove(at: hit)
            injectionCache.insert(entry, at: 0)
            return entry.tokens
        }
        let parser: Parser
        if let known = injectionParsers[language] {
            parser = known
        } else {
            parser = Parser()
            do { try parser.setLanguage(language.grammar) } catch { return [] }
            injectionParsers[language] = parser
        }
        guard let text = textProvider(region.range), let tree = parser.parse(text) else { return [] }
        var found: [HighlightToken] = []
        for match in language.query.execute(in: tree) {
            for capture in match.captures {
                if let name = capture.name, let kind = TokenKind(rawValue: name), capture.range.length > 0 { found.append(HighlightToken(kind: kind, range: capture.range)) }
            }
        }
        let tokens = Self.outerFirst(found)
        injectionCache.insert((key, tokens), at: 0)
        if injectionCache.count > Self.injectionCacheSize { injectionCache.removeLast() }
        return tokens
    }

    private func inlineTokens(for nodes: [NSRange], clippedTo range: NSRange) -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        var seen = Set<Int>()
        for node in nodes where node.length <= Self.maxInlineLength && seen.insert(node.location).inserted {
            guard let text = textProvider(node), let tree = inlineParser.parse(text) else { continue }
            let cursor = Grammar.inlineQuery.execute(in: tree)
            var found: [HighlightToken] = []
            for match in cursor {
                for capture in match.captures {
                    guard let name = capture.name, let kind = TokenKind(rawValue: name) else { continue }
                    let shifted = NSRange(location: capture.range.location + node.location, length: capture.range.length)
                    if let clipped = Self.clip(shifted, to: range) { found.append(HighlightToken(kind: kind, range: clipped)) }
                }
            }
            tokens += Self.outerFirst(found)
        }
        return tokens
    }

    static func clip(_ r: NSRange, to bounds: NSRange) -> NSRange? {
        let clipped = NSIntersectionRange(r, bounds)
        return clipped.length > 0 ? clipped : nil
    }

    /// Apply order matters (later wins for colour, traits accumulate): start ascending, longer first.
    static func outerFirst(_ tokens: [HighlightToken]) -> [HighlightToken] {
        tokens.enumerated().sorted { a, b in
            if a.element.range.location != b.element.range.location { return a.element.range.location < b.element.range.location }
            if a.element.range.length != b.element.range.length { return a.element.range.length > b.element.range.length }
            return a.offset < b.offset
        }.map(\.element)
    }
}
