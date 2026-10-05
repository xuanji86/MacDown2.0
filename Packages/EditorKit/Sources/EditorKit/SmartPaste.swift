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

    /// The edit for pasting `clipboard` over `selection` of `text`, or nil when this is an ordinary paste: no selection,
    /// clipboard not a single URL, a selection that spans lines, is blank, holds brackets (they would need escaping and the
    /// text would change), or is itself a URL (the user is replacing a URL by another). The caret ends after the link.
    static func linkEdit(clipboard: String, selection: NSRange, in text: NSString) -> TextEdit? {
        guard selection.length > 0, NSMaxRange(selection) <= text.length, let url = url(in: clipboard) else { return nil }
        let label = text.substring(with: selection)
        guard label.rangeOfCharacter(from: .newlines) == nil, !label.contains("["), !label.contains("]"),
              !label.trimmingCharacters(in: .whitespaces).isEmpty, Self.url(in: label) == nil
        else { return nil }
        let link = "[\(label)](\(url))"
        return TextEdit(range: selection, replacement: link, selection: NSRange(location: selection.location + (link as NSString).length, length: 0))
    }
}
