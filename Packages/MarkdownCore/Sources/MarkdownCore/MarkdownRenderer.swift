import Foundation

/// Identifies a document flavor: "markdown" (core) or one registered by an enabled extension, e.g. "quarto".
public struct FlavorID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static let markdown: FlavorID = "markdown"
}

/// Raw values are the names `Web/src/render/index.ts` looks for in `RenderOptions.extensions`.
public enum MarkdownExtension: String, Codable, Sendable, CaseIterable {
    case tables, strikethrough, autolink, smartPunctuation
    case mark, sup, sub, underline, footnotes, taskLists, math, toc, frontMatter, cjkEmphasis
    /// `:smile:` short codes (GitHub's names). Off by default; GitHub alerts (`> [!NOTE]`) are always on and have no switch.
    case emoji
}

/// What the preview shows for a leading front matter block, YAML between `---` or TOML between `+++` (Hugo); the raw text is always in `RenderResult.frontMatter`.
public enum FrontMatterDisplay: String, Codable, Sendable, CaseIterable {
    case hidden, table
}

/// Encoded as JSON and handed to `MacDown2.render` in `Web/src/render/index.ts`; keep the two in sync.
/// Defaults follow PLAN §4.8 (Markdown / Rendering settings pages).
public struct RenderOptions: Sendable, Codable, Hashable {
    public var flavor: FlavorID = .markdown
    public var renderChunks: [String] = []
    public var extensions: Set<MarkdownExtension> = [
        .tables, .strikethrough, .autolink, .mark, .footnotes, .taskLists, .math, .toc, .frontMatter, .cjkEmphasis,
    ]
    public var hardBreaks = false
    public var allowRawHTML = true
    public var codeHighlighting = true
    public var codeLineNumbers = false
    public var headingAnchors = true
    /// Inline `$…$`. Off by default (as in MacDown 1) so prices like "$5 to $10" stay text; `$$…$$`, `\(…\)` and `\[…\]` are always on with `.math`.
    public var inlineDollarMath = false
    public var frontMatterDisplay: FrontMatterDisplay = .hidden
    /// Text of the files a flavor may read while rendering (Quarto `{{< include >}}`), by path relative to the document
    /// folder. The renderer cannot read files; the caller collects them (`DocumentFlavor.auxiliaryFiles`).
    public var files: [String: String] = [:]
    /// Output that leaves the app (Copy HTML, export, PDF, `macdown2 render`): script, frames, event handlers and script URLs are
    /// removed from `RenderResult.html`. Off for the preview, which keeps the document's raw HTML and defends itself with a CSP.
    public var sanitize = false

    /// These options for output that leaves the app: Copy HTML, export, PDF, print, `macdown2 render`.
    public var forExport: RenderOptions {
        var options = self
        options.sanitize = true
        return options
    }

    public init() {}
}

public struct RenderResult: Sendable, Codable, Hashable {
    public var html: String
    public var blocks: [BlockMap]
    /// The task-list checkboxes of this text, in document order.
    public var tasks: [TaskItem]
    public var outline: [OutlineItem]
    public var stats: TextStats
    /// Raw text between the `---` (YAML) or `+++` (TOML) fences; nil when there is none or `.frontMatter` is off.
    public var frontMatter: String?
}

/// A task-list checkbox as the renderer saw it (`Web/src/render/index.ts`): `line` is the 0-based source line the preview page
/// reports for it (`data-line` of its paragraph in a loose item, of its list item otherwise), `mark` the line that holds its
/// `[ ]` (different only for an item that starts with an empty bullet line). `TaskToggle` edits the source from this.
public struct TaskItem: Sendable, Codable, Hashable {
    public var line: Int
    public var mark: Int
    public init(line: Int, mark: Int) {
        self.line = line
        self.mark = mark
    }
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
