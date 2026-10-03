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

    private let client: TreeSitterClient
    private let inlineParser = Parser()

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

    /// `range`/`delta` are the pre-edit range and the length change, as in Neon (`NSTextStorage` `editedRange` with
    /// `changeInLength` already subtracted). `snapshot` must be immutable: Neon may parse it on a background queue.
    public func didChangeContent(to snapshot: NSString, in range: NSRange, delta: Int, completion: @escaping () -> Void = {}) {
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
        for match in cursor {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                if name == Grammar.inlineCapture {
                    inlineNodes.append(capture.range)
                } else if let kind = TokenKind(rawValue: name), let clipped = Self.clip(capture.range, to: range) {
                    block.append(HighlightToken(kind: kind, range: clipped))
                }
            }
        }
        return Self.outerFirst(block) + inlineTokens(for: inlineNodes, clippedTo: range)
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
