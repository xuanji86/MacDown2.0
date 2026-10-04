import Foundation

/// Checking a task-list box in the preview: which single character of the source to change.
///
/// Works on the document's LF text (what the editor holds; `MarkdownFile` restores CRLF / CR and the encoding on save),
/// with UTF-16 offsets so the result can go straight into an `NSTextView`. The edit is the one character between the
/// brackets of `[ ]` / `[x]`, nothing else, so the file's bytes stay as they were everywhere else.
///
/// The page names the task by the source line of its list item, as markdown-it numbered it for exactly this text (the
/// caller has already checked that). This type confirms the line really is a task item and asks for a change: the same
/// marker grammar as `@mdit/plugin-tasklist` (`[ ]`, `[x]`, `[X]` or a no-break space as the mark, then a space or
/// no-break space and some text), after any mix of indentation, `>` quotes and list markers.
public enum TaskToggle {
    public struct Edit: Equatable, Sendable {
        /// The mark inside the brackets: always one UTF-16 unit.
        public let range: NSRange
        /// `"x"` to check, `" "` to uncheck.
        public let replacement: String
    }

    /// The edit that makes the task item on `line` (0-based) `checked`, or nil when there is nothing to do or it would
    /// be wrong to: the line does not exist, is not a task item (any more), is inside a fenced code block or front
    /// matter, or is already in the requested state.
    public static func edit(in text: String, line: Int, checked: Bool) -> Edit? {
        guard line >= 0 else { return nil }
        let u = Array(text.utf16)
        var lines: [Range<Int>] = []  // every line; "a\n" has two, the second empty
        var start = 0
        for (i, unit) in u.enumerated() where unit == lf {
            lines.append(start..<i)
            start = i + 1
        }
        lines.append(start..<u.count)
        guard line < lines.count else { return nil }

        var first = 0
        if let close = frontMatterEnd(u, lines) {
            if line <= close { return nil }
            first = close + 1
        }
        var fence: Fence?
        for n in first..<line { update(&fence, u, lines[n]) }
        if fence != nil { return nil }

        guard let mark = markOffset(u, lines[line]) else { return nil }
        let isChecked = u[mark] == 0x78 || u[mark] == 0x58  // x X
        guard isChecked != checked else { return nil }
        return Edit(range: NSRange(location: mark, length: 1), replacement: checked ? "x" : " ")
    }

    // lazy: indented code blocks, HTML blocks and `$$` math blocks are not recognised, and a fence is only noticed when it
    // sits within 3 spaces of its container prefix. The page never names a line inside those (they render no checkbox) and
    // the caller has matched the text the page rendered, so this is a second check, not the first. Upgrade path: send the
    // checkbox's ordinal and verify it against a parse of the text.

    private static let lf: UInt16 = 0x0A

    // MARK: Marker

    /// Offset of the mark character when the line is a task item, else nil.
    private static func markOffset(_ u: [UInt16], _ line: Range<Int>) -> Int? {
        let end = line.upperBound
        var p = line.lowerBound
        var afterMarker = false
        while p < end {
            let q = skipBlanks(u, p, end)
            if afterMarker, q > p, let mark = taskMark(u, q, end) { return mark }
            p = q
            guard p < end else { return nil }
            if u[p] == 0x3E {  // > quote
                p += 1
                afterMarker = false
            } else if let after = listMarker(u, p, end) {
                guard after < end, u[after] == 0x20 || u[after] == 0x09 else { return nil }  // `-[ ]` is not a list item
                p = after
                afterMarker = true
            } else {
                return nil
            }
        }
        return nil
    }

    /// `[`, space | x | X | NBSP, `]`, space | NBSP, then some text on the line; returns the mark's offset.
    private static func taskMark(_ u: [UInt16], _ p: Int, _ end: Int) -> Int? {
        guard p + 4 < end, u[p] == 0x5B, u[p + 2] == 0x5D, u[p + 3] == 0x20 || u[p + 3] == 0xA0 else { return nil }
        guard skipBlanks(u, p + 4, end) < end else { return nil }  // "- [ ] " alone: the renderer trims it to "[ ]", not a task
        switch u[p + 1] {
        case 0x20, 0xA0, 0x78, 0x58: return p + 1
        default: return nil
        }
    }

    /// End of a bullet (`-` `+` `*`) or ordered (`1.` / `1)`, up to 9 digits) marker starting at `p`.
    private static func listMarker(_ u: [UInt16], _ p: Int, _ end: Int) -> Int? {
        if u[p] == 0x2D || u[p] == 0x2B || u[p] == 0x2A { return p + 1 }
        var q = p
        while q < end, q - p < 9, u[q] >= 0x30, u[q] <= 0x39 { q += 1 }
        guard q > p, q < end, u[q] == 0x2E || u[q] == 0x29 else { return nil }
        return q + 1
    }

    private static func skipBlanks(_ u: [UInt16], _ p: Int, _ end: Int) -> Int {
        var q = p
        while q < end, u[q] == 0x20 || u[q] == 0x09 { q += 1 }
        return q
    }

    // MARK: Fenced code and front matter

    private struct Fence {
        let char: UInt16
        let length: Int
    }

    /// Tracks ``` / ~~~ fences line by line: opens on a run of 3+ (a backtick fence's info string has no backtick), closes on
    /// a run of the same character at least as long with nothing after it.
    private static func update(_ fence: inout Fence?, _ u: [UInt16], _ line: Range<Int>) {
        let end = line.upperBound
        var p = line.lowerBound
        var indent = 0
        while p < end {  // past this line's container prefix: indentation, `>` quotes, list markers
            let q = skipBlanks(u, p, end)
            indent = q - p
            p = q
            guard p < end else { return }
            if u[p] == 0x3E {
                p += 1
            } else if let after = listMarker(u, p, end), after < end, u[after] == 0x20 || u[after] == 0x09 {
                p = after
            } else {
                break
            }
            indent = 0
        }
        guard p < end, indent <= 3, u[p] == 0x60 || u[p] == 0x7E else { return }
        let char = u[p]
        var run = 0
        while p + run < end, u[p + run] == char { run += 1 }
        guard run >= 3 else { return }
        let rest = (p + run)..<end
        if let open = fence {
            if char == open.char, run >= open.length, skipBlanks(u, rest.lowerBound, end) == end { fence = nil }
        } else if char == 0x7E || !u[rest].contains(0x60) {
            fence = Fence(char: char, length: run)
        }
    }

    /// Index of the line closing front matter: `---` (or `+++`) alone on the first line, then the same marker (YAML also
    /// `...`) alone on a later one. nil when the document does not start that way or never closes it.
    private static func frontMatterEnd(_ u: [UInt16], _ lines: [Range<Int>]) -> Int? {
        func marker(_ r: Range<Int>) -> UInt16? {
            guard r.count >= 3, u[r.lowerBound] == 0x2D || u[r.lowerBound] == 0x2B else { return nil }
            let c = u[r.lowerBound]
            var q = r.lowerBound
            while q < r.upperBound, u[q] == c { q += 1 }
            return q - r.lowerBound == 3 && skipBlanks(u, q, r.upperBound) == r.upperBound ? c : nil
        }
        guard let open = marker(lines[0]) else { return nil }
        return lines.indices.dropFirst().first { n in
            marker(lines[n]) == open || (open == 0x2D && lines[n].count == 3 && u[lines[n]].allSatisfy { $0 == 0x2E })
        }
    }
}
