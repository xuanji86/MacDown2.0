import Foundation

/// Everything that changes the head of whole lines: headings, lists, quotes, indentation. Each command returns, per
/// line, "replace the first `oldLength` UTF-16 units with `newPrefix`"; `Lines.apply` turns that into one `TextEdit`
/// and carries the selection along.

/// The structural head of a line: `> ` quote levels, indentation, list marker and task box.
struct LinePrefix {
    var quote = "", indent = ""
    var marker: String?
    var spacing = ""
    var task: String?
    /// UTF-16 length of the whole prefix.
    var length = 0

    var isOrdered: Bool { marker.map { $0.hasSuffix(".") || $0.hasSuffix(")") } ?? false }
    var isUnordered: Bool { marker != nil && !isOrdered }

    private static let regex = try! NSRegularExpression(pattern: #"^((?:[ \t]*>[ \t]?)*)([ \t]*)(?:([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\][ \t]+)?)?"#)

    init(_ line: String) {
        let ns = line as NSString
        guard let m = Self.regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        quote = group(1) ?? ""
        indent = group(2) ?? ""
        marker = group(3)
        spacing = group(4) ?? ""
        task = group(5)
        length = m.range.length
    }
}

struct Line {
    var start: Int
    var length: Int  // without the terminator
    var terminatorLength: Int
    var text: String
    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
}

struct PrefixChange {
    var oldLength: Int
    var newPrefix: String
}

enum Lines {
    /// The lines the selection touches. A selection that ends right after a newline (a whole line selected) does not
    /// reach into the next line.
    static func selected(_ text: NSString, _ sel: NSRange) -> [Line] {
        var end = NSMaxRange(sel)
        if sel.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        let region = text.lineRange(for: NSRange(location: sel.location, length: end - sel.location))
        var lines: [Line] = []
        var location = region.location
        repeat {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(Line(
                start: lineStart, length: contentsEnd - lineStart, terminatorLength: lineEnd - contentsEnd,
                text: text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            ))
            location = lineEnd
        } while location < NSMaxRange(region)
        return lines
    }

    /// Apply `change` to every line as one replacement of the region from the first line's start to the last line's
    /// end; nil if no line changes.
    static func apply(_ text: NSString, _ lines: [Line], _ sel: NSRange, _ change: (Line) -> PrefixChange?) -> TextEdit? {
        guard let first = lines.first, let last = lines.last else { return nil }
        struct Mapped { var oldStart: Int, oldLength: Int, newStart: Int, oldPrefix: Int, newPrefix: Int }
        var out = "", mapped: [Mapped] = [], changed = false
        for (i, line) in lines.enumerated() {
            let c = change(line)
            let oldPrefix = min(c?.oldLength ?? 0, line.length), newPrefix = c?.newPrefix ?? ""
            if c != nil, text.substring(with: NSRange(location: line.start, length: oldPrefix)) != newPrefix { changed = true }
            mapped.append(Mapped(oldStart: line.start, oldLength: line.length, newStart: out.utf16.count, oldPrefix: oldPrefix, newPrefix: newPrefix.utf16.count))
            out += newPrefix + text.substring(with: NSRange(location: line.start + oldPrefix, length: line.length - oldPrefix))
            if i < lines.count - 1 { out += text.substring(with: NSRange(location: line.start + line.length, length: line.terminatorLength)) }
        }
        guard changed else { return nil }
        let regionEnd = last.start + last.length
        let delta = out.utf16.count - (regionEnd - first.start)
        // A caret at a line start ends up after the new prefix (type on); a selection starting there keeps covering it.
        func map(_ offset: Int, selectionStart: Bool = false) -> Int {
            guard offset <= regionEnd else { return offset + delta }
            guard let m = mapped.last(where: { $0.oldStart <= offset }) else { return offset }
            let p = offset - m.oldStart
            if selectionStart && p == 0 { return first.start + m.newStart }
            let moved = p >= m.oldPrefix ? p - m.oldPrefix + m.newPrefix : min(p, m.newPrefix)
            return first.start + m.newStart + moved
        }
        let s = map(sel.location, selectionStart: sel.length > 0), e = map(NSMaxRange(sel))
        return TextEdit(range: NSRange(location: first.start, length: regionEnd - first.start), replacement: out, selection: NSRange(location: s, length: e - s))
    }

    // MARK: Headings

    /// UTF-16 length of an ATX heading head (`  ## `), 0 if the line is not a heading.
    static func headingPrefixLength(_ line: String) -> Int {
        let u = Array(line.utf16)
        var i = 0
        while i < u.count, i < 3, u[i] == 0x20 { i += 1 }
        let hashes = i
        while i < u.count, u[i] == 0x23 { i += 1 }
        guard i - hashes >= 1, i - hashes <= 6, i == u.count || u[i] == 0x20 || u[i] == 0x09 else { return 0 }
        while i < u.count, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        return i
    }

    /// level 0 = plain paragraph. Blank lines in a multi-line selection stay blank.
    static func heading(_ text: NSString, _ sel: NSRange, level: Int) -> TextEdit? {
        let lines = selected(text, sel)
        let new = level == 0 ? "" : String(repeating: "#", count: level) + " "
        return apply(text, lines, sel) { line in
            if lines.count > 1 && line.isBlank { return nil }
            return PrefixChange(oldLength: headingPrefixLength(line.text), newPrefix: new)
        }
    }

    // MARK: Lists and quotes (toggles)

    /// Lines the toggle looks at: blank ones are skipped in a multi-line selection (paragraph gaps stay gaps).
    private static func content(_ lines: [Line]) -> [Line] { lines.count > 1 ? lines.filter { !$0.isBlank } : lines }

    static func unorderedList(_ text: NSString, _ sel: NSRange, _ behavior: EditorBehavior) -> TextEdit? {
        let lines = selected(text, sel)
        let remove = !lines.isEmpty && content(lines).allSatisfy { LinePrefix($0.text).isUnordered }
        return apply(text, lines, sel) { line in
            if lines.count > 1 && line.isBlank { return nil }
            let p = LinePrefix(line.text)
            let head = p.quote + p.indent
            return PrefixChange(oldLength: p.length, newPrefix: remove ? head : head + String(behavior.unorderedListMarker) + " " + (p.task ?? ""))
        }
    }

    static func orderedList(_ text: NSString, _ sel: NSRange) -> TextEdit? {
        let lines = selected(text, sel)
        let remove = !lines.isEmpty && content(lines).allSatisfy { LinePrefix($0.text).isOrdered }
        var number = 0
        return apply(text, lines, sel) { line in
            if lines.count > 1 && line.isBlank { return nil }
            let p = LinePrefix(line.text)
            let head = p.quote + p.indent
            number += 1
            return PrefixChange(oldLength: p.length, newPrefix: remove ? head : head + "\(number). " + (p.task ?? ""))
        }
    }

    /// Adds one `> ` level (blank lines inside a multi-line selection get a bare `>` so the quote stays one block), or
    /// removes the outermost level when every line is already quoted.
    static func blockquote(_ text: NSString, _ sel: NSRange) -> TextEdit? {
        let lines = selected(text, sel)
        let remove = !lines.isEmpty && content(lines).allSatisfy { !LinePrefix($0.text).quote.isEmpty }
        return apply(text, lines, sel) { line in
            if remove {
                let quote = LinePrefix(line.text).quote
                guard !quote.isEmpty else { return nil }
                return PrefixChange(oldLength: quote.utf16.count, newPrefix: dropFirstLevel(quote))
            }
            return PrefixChange(oldLength: 0, newPrefix: lines.count > 1 && line.isBlank ? ">" : "> ")
        }
    }

    /// `"> > "` -> `"> "`: skips leading blanks, one `>` and its optional space.
    private static func dropFirstLevel(_ quote: String) -> String {
        var rest = Substring(quote).drop { $0 == " " || $0 == "\t" }
        if rest.first == ">" { rest = rest.dropFirst() }
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    // MARK: Indentation

    static func indentUnit(_ behavior: EditorBehavior) -> String {
        behavior.tabInsertsSpaces ? String(repeating: " ", count: max(behavior.tabWidth, 1)) : "\t"
    }

    static func indent(_ text: NSString, _ sel: NSRange, _ behavior: EditorBehavior) -> TextEdit? {
        let lines = selected(text, sel)
        let unit = indentUnit(behavior)
        return apply(text, lines, sel) { line in
            lines.count > 1 && line.isBlank ? nil : PrefixChange(oldLength: 0, newPrefix: unit)
        }
    }

    /// Removes one tab, or up to `tabWidth` spaces, from the start of each line.
    static func outdent(_ text: NSString, _ sel: NSRange, _ behavior: EditorBehavior) -> TextEdit? {
        let lines = selected(text, sel)
        return apply(text, lines, sel) { line in
            let u = Array(line.text.utf16)
            var n = 0
            if u.first == 0x09 { n = 1 } else { while n < u.count, n < max(behavior.tabWidth, 1), u[n] == 0x20 { n += 1 } }
            return n == 0 ? nil : PrefixChange(oldLength: n, newPrefix: "")
        }
    }
}
