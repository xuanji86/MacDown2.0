import Foundation

/// Identifies a document flavor: "markdown" (core) or one registered by an enabled extension, e.g. "quarto".
public struct FlavorID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static let markdown: FlavorID = "markdown"
}

public enum MarkdownExtension: String, Codable, Sendable, CaseIterable {
    case tables, strikethrough, autolink, smartPunctuation
}

/// Encoded as JSON and handed to `MacDown2.render` in `Web/src/render/index.ts`; keep the two in sync.
public struct RenderOptions: Sendable, Codable, Hashable {
    public var flavor: FlavorID = .markdown
    public var renderChunks: [String] = []
    public var extensions: Set<MarkdownExtension> = [.tables, .strikethrough, .autolink]
    public var hardBreaks = false
    public var allowRawHTML = true
    public var headingAnchors = true

    public init() {}
}

public struct RenderResult: Sendable, Codable, Hashable {
    public var html: String
    public var blocks: [BlockMap]
    public var outline: [OutlineItem]
    public var stats: TextStats
}

/// A top-level block and the source lines it came from (`lineEnd` exclusive, zero-based).
public struct BlockMap: Sendable, Codable, Hashable {
    public var lineStart: Int
    public var lineEnd: Int
    public var hash: UInt64
}

public struct OutlineItem: Sendable, Codable, Hashable {
    public var level: Int
    public var text: String
    public var slug: String
    public var line: Int
}

public struct TextStats: Sendable, Codable, Hashable {
    public var words: Int
    public var characters: Int
    public var charactersNoSpaces: Int
}

public protocol MarkdownRenderer: Sendable {
    func render(_ source: String, options: RenderOptions) async throws -> RenderResult
}
