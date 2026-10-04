import Foundation

public enum LineEnding: Sendable, Equatable {
    case lf, crlf
}

/// A UTF-8 Markdown file as the editor sees it: always LF text, with the file's own line-ending style and BOM remembered
/// so saving restores them. Pure functions, shared by the document class and the tests.
public struct MarkdownFile: Sendable, Equatable {
    public var text: String
    public var lineEnding: LineEnding
    public var hasBOM: Bool

    public init(text: String = "", lineEnding: LineEnding = .lf, hasBOM: Bool = false) {
        self.text = text
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    private static let bom = Data([0xEF, 0xBB, 0xBF])

    /// Strict: invalid UTF-8 fails the open, so it can never be silently corrupted by the next save.
    public static func decode(_ data: Data) throws -> MarkdownFile {
        let hasBOM = data.starts(with: bom)
        guard let raw = String(data: hasBOM ? data.dropFirst(bom.count) : data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return MarkdownFile(text: normalized(raw), lineEnding: raw.contains("\r\n") ? .crlf : .lf, hasBOM: hasBOM)
    }

    public func encoded() -> Data {
        var out = Self.normalized(text)  // pasted text may carry CRLF; settle on LF first
        if lineEnding == .crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data(out.utf8)
        if hasBOM { data.insert(contentsOf: Self.bom, at: 0) }
        return data
    }

    // Foundation replace works on UTF-16, so "\r\n" is not treated as one Character like in Swift's own String API.
    public static func normalized(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n") }
}
