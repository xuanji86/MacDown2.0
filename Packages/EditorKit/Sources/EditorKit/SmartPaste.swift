import Foundation

/// A URL pasted over selected text turns the selection into a link: `[selection](url)`. Everything else pastes as plain text.
enum SmartPaste {
    private static let schemes: Set<String> = ["http", "https", "ftp", "mailto"]

    /// The URL held by `clipboard` when the whole clipboard is exactly one (surrounding blanks ignored): no spaces inside,
    /// a web scheme with a host, or `mailto:` with an address. Parentheses are percent-encoded when unbalanced, because the
    /// destination of a Markdown link ends at the first unmatched `)`.
    static func url(in clipboard: String) -> String? {
        let s = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !s.contains("<"), !s.contains(">"),
              let parts = URLComponents(string: s), let scheme = parts.scheme?.lowercased(), schemes.contains(scheme)
        else { return nil }
        if scheme == "mailto" ? parts.path.isEmpty : (parts.host ?? "").isEmpty { return nil }
        return balanced(s) ? s : s.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    private static func balanced(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        return depth == 0
    }

    /// The selection is the text of an existing link (`[do|cs](old)`) or its destination (`[docs](o|ld)`): wrapping it again would nest links.
    // lazy: looks at the selection's own line only (a link text split over two lines is not recognised)
    private static func isInsideLink(_ selection: NSRange, in text: NSString) -> Bool {
        let line = text.lineRange(for: selection)
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let after = text.substring(with: NSRange(location: NSMaxRange(selection), length: NSMaxRange(line) - NSMaxRange(selection)))
        // Link text: an unclosed `[` before, and a `]` after with no new `[` in between.
        if let open = before.lastIndex(of: "["), !before[open...].contains("]"),
           let close = after.firstIndex(of: "]"), !after[..<close].contains("[") { return true }
        // Destination: `](` before and the closing `)` after.
        if let paren = before.range(of: "](", options: .backwards), !before[paren.upperBound...].contains(")"), after.contains(")") { return true }
        return false
    }

    /// The edit for pasting `clipboard` over `selection` of `text`, or nil when this is an ordinary paste: no selection,
    /// clipboard not a single URL, a selection that spans lines, is blank, holds brackets (they would need escaping and the
    /// text would change), or is itself a URL (the user is replacing a URL by another). The caret ends after the link.
    static func linkEdit(clipboard: String, selection: NSRange, in text: NSString) -> TextEdit? {
        guard selection.length > 0, NSMaxRange(selection) <= text.length, let url = url(in: clipboard) else { return nil }
        let label = text.substring(with: selection)
        guard label.rangeOfCharacter(from: .newlines) == nil, !label.contains("["), !label.contains("]"),
              !label.trimmingCharacters(in: .whitespaces).isEmpty, Self.url(in: label) == nil
        else { return nil }
        guard !isInsideLink(selection, in: text) else { return nil }
        let link = "[\(label)](\(url))"
        return TextEdit(range: selection, replacement: link, selection: NSRange(location: selection.location + (link as NSString).length, length: 0))
    }
}
