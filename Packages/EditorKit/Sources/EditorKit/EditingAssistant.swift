import Foundation

/// Typing assistance (PLAN §4.3.4): auto-pairing, list/quote continuation, Tab handling. Pure functions of the text and
/// selection; each returns nil when the keystroke should just do what the text view does by default. The view must not
/// call these while an input method has marked text.
enum EditingAssistant {
    // MARK: Auto-pair

    private static let openers: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "*": "*", "_": "_",
    ]
    private static let closers: Set<Character> = [")", "]", "}"]

    /// A single typed character `typed`. Wraps a selection, types over an auto-inserted closer, or inserts a pair.
    // lazy: pairs are not tracked, so typing a closer next to an identical character always steps over it, and a pair
    // typed inside a fenced code block still pairs; track auto-inserted pairs / consult the highlighter's block map if it annoys.
    static func typed(_ typed: String, in text: NSString, selection sel: NSRange, behavior: EditorBehavior) -> TextEdit? {
        guard behavior.autoPair, typed.utf16.count == 1, let c = typed.first, openers[c] != nil || closers.contains(c) else { return nil }
        let start = sel.location, end = NSMaxRange(sel)

        if sel.length > 0 {
            guard let close = openers[c] else { return nil }
            let inner = text.substring(with: sel)
            return TextEdit(range: sel, replacement: "\(c)\(inner)\(close)", selection: NSRange(location: start + 1, length: sel.length))
        }
        let prev = character(before: start, in: text), next = character(at: end, in: text)

        if next == c, closers.contains(c) || openers[c] == c {
            if c == "*" || c == "_", let edit = expandEmptyPair(c, in: text, at: start) { return edit }
            return TextEdit(range: sel, replacement: "", selection: NSRange(location: start + 1, length: 0))  // step over
        }
        guard let close = openers[c] else { return nil }

        let pair: Bool
        switch c {
        case "(", "[", "{":
            pair = !isWord(next)
        case "*", "_":
            pair = !isWord(prev) && !isWord(next) && prev != c && !(c == "*" && onlyBlanksBefore(start, in: text))
        default:  // quotes, backtick: `don't`, `5'` stay single
            pair = !isWord(prev) && !isWord(next)
        }
        guard pair else { return nil }
        return TextEdit(range: sel, replacement: "\(c)\(close)", selection: NSRange(location: start + 1, length: 0))
    }

    /// `*|*` + `*` -> `**|**` (and the same for `_`): a bold/underline pair rather than stepping over.
    private static func expandEmptyPair(_ c: Character, in text: NSString, at caret: Int) -> TextEdit? {
        let u = c.utf16.first!
        var before = caret, after = caret
        while before > 0, text.character(at: before - 1) == u { before -= 1 }
        while after < text.length, text.character(at: after) == u { after += 1 }
        guard caret - before == 1, after - caret == 1, !isWord(character(before: before, in: text)) else { return nil }
        return TextEdit(range: NSRange(location: caret, length: 0), replacement: "\(c)\(c)", selection: NSRange(location: caret + 1, length: 0))
    }

    /// Backspace between an empty pair (`(|)`, `"|"`, `**|**`, ...) removes both halves.
    static func backspace(in text: NSString, selection sel: NSRange, behavior: EditorBehavior) -> TextEdit? {
        guard behavior.autoPair, sel.length == 0, sel.location > 0, sel.location < text.length,
              let prev = character(before: sel.location, in: text), let next = character(at: sel.location, in: text),
              openers[prev] == next,
              prev.utf16.count == 1, next.utf16.count == 1  // `character(...)` may be a multi-unit cluster; markers are single units
        else { return nil }
        return TextEdit(range: NSRange(location: sel.location - 1, length: 2), replacement: "", selection: NSRange(location: sel.location - 1, length: 0))
    }

    // MARK: Return

    /// Return: continue `- `, `1. `, `- [ ] `, `> ` (and indentation), or end the list on an empty item.
    static func newline(in text: NSString, selection sel: NSRange, behavior: EditorBehavior) -> TextEdit? {
        guard behavior.continueLists else { return nil }
        var lineStart = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: sel.location, length: 0))
        guard sel.location <= contentsEnd else { return nil }
        let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let p = LinePrefix(line)
        let col = sel.location - lineStart
        let structural = p.marker != nil || !p.quote.isEmpty
        let body = (line as NSString).substring(from: p.length)
        let bodyIsEmpty = body.allSatisfy { $0 == " " || $0 == "\t" }

        if structural, sel.length == 0, bodyIsEmpty, col >= p.length {
            // Empty item: leave the list (a quoted list keeps its quote), nothing is inserted.
            let kept = p.marker != nil ? p.quote : ""
            return TextEdit(
                range: NSRange(location: lineStart, length: contentsEnd - lineStart), replacement: kept,
                selection: NSRange(location: lineStart + kept.utf16.count, length: 0)
            )
        }
        guard col >= p.length else { return nil }  // caret inside the marker: plain newline
        let next: String
        if structural {
            var marker = ""
            if let m = p.marker {
                marker = nextMarker(m, autoNumber: behavior.autoNumberLists) + p.spacing + (p.task == nil ? "" : "[ ] ")
            }
            next = p.quote + p.indent + marker
        } else if !p.indent.isEmpty, !bodyIsEmpty {
            next = p.indent  // continued indentation (indented code, aligned prose)
        } else {
            return nil
        }
        return TextEdit(range: sel, replacement: "\n" + next, selection: NSRange(location: sel.location + 1 + next.utf16.count, length: 0))
    }

    private static func nextMarker(_ marker: String, autoNumber: Bool) -> String {
        guard let delimiter = marker.last, delimiter == "." || delimiter == ")", let n = Int(marker.dropLast()) else { return marker }
        return "\(autoNumber ? n + 1 : n)\(delimiter)"
    }

    // MARK: Tab

    /// Tab: indent a list item (caret anywhere on it) or a multi-line selection; otherwise insert a tab stop's worth of
    /// spaces. nil = let the text view insert a real tab.
    static func tab(in text: NSString, selection sel: NSRange, behavior: EditorBehavior) -> TextEdit? {
        let lines = Lines.selected(text, sel)
        let listItem = behavior.continueLists && lines.count == 1 && LinePrefix(lines[0].text).marker != nil
        if listItem || lines.count > 1 { return Lines.indent(text, sel, behavior) }
        guard behavior.tabInsertsSpaces else { return nil }
        let width = max(behavior.tabWidth, 1)
        let column = sel.location - lines[0].start
        let spaces = String(repeating: " ", count: width - column % width)
        return TextEdit(range: sel, replacement: spaces, selection: NSRange(location: sel.location + spaces.utf16.count, length: 0))
    }

    /// Shift-Tab: outdent the lines the selection touches.
    static func backtab(in text: NSString, selection sel: NSRange, behavior: EditorBehavior) -> TextEdit? {
        Lines.outdent(text, sel, behavior)
    }

    // MARK: Character helpers

    static func character(before offset: Int, in text: NSString) -> Character? {
        guard offset > 0, offset <= text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: offset - 1)).first
    }

    static func character(at offset: Int, in text: NSString) -> Character? {
        guard offset >= 0, offset < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: offset)).first
    }

    private static func onlyBlanksBefore(_ offset: Int, in text: NSString) -> Bool {
        var lineStart = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: offset, length: 0))
        return text.substring(with: NSRange(location: lineStart, length: offset - lineStart)).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Letters and digits of alphabetic scripts. CJK ideographs, kana and hangul are not "word" characters: they are
    /// not separated by spaces, so a quote or bracket next to them is still at a boundary.
    static func isWord(_ ch: Character?) -> Bool {
        guard let ch, ch.isLetter || ch.isNumber || ch == "_" else { return false }
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return false
        default: return true
        }
    }
}
