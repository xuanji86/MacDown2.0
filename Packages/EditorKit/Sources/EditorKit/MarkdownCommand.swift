import Foundation

/// One replacement in the editor text. All offsets are UTF-16 (NSString), so emoji and other surrogate pairs need no
/// special care as long as edits never split one; none of the markers inserted here are non-ASCII.
public struct TextEdit: Equatable, Sendable {
    /// Range replaced, in the text before the edit.
    public var range: NSRange
    public var replacement: String
    /// Selection to set afterwards, in the text after the edit.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// The editing-assistance settings of PLAN §5.4 (driven by the Editor settings page; defaults are the
/// original MacDown's).
public struct EditorBehavior: Equatable, Sendable {
    /// Auto-pair brackets, quotes and `*` `_` `` ` ``.
    public var autoPair = true
    /// Return continues list, task-list and quote prefixes; Tab/Shift-Tab indent list items.
    public var continueLists = true
    /// Return after `3.` produces `4.`; off repeats the number.
    public var autoNumberLists = true
    public var tabInsertsSpaces = true
    public var tabWidth = 4
    /// Marker the "unordered list" command writes.
    public var unorderedListMarker: Character = "-"

    public init() {}
}

/// Menu and toolbar formatting commands. `edit(...)` is a pure function of the text; `MarkdownTextView.perform`
/// applies it through the text system so it is undoable.
public enum MarkdownCommand: Equatable, Sendable {
    case bold, italic, underline, strikethrough, highlight, inlineCode
    /// `<!-- … -->`: wraps the selection, or removes the comment markers around it.
    case comment
    /// 1...6; out-of-range levels are clamped.
    case heading(Int)
    case paragraph
    /// Toggles: applying the command to lines that already have the marker removes it.
    case unorderedList, orderedList, blockquote
    case codeBlock
    /// A page break for PDF / print on a line of its own (`MarkdownCommand.pageBreakMarker`), after the selection's last line.
    case pageBreak
    /// Wrap the selection; a URL on the clipboard (or the selection itself being a URL) is filled in.
    case link, image
    case indent, outdent

    /// The replacement for `selection` in `text`, or nil when the command would change nothing.
    public func edit(in text: NSString, selection: NSRange, clipboard: String? = nil, behavior: EditorBehavior = .init()) -> TextEdit? {
        switch self {
        case .bold: return Inline.toggle(text, selection, "**", "**")
        case .italic: return Inline.toggle(text, selection, "*", "*")
        case .underline: return Inline.toggle(text, selection, "<u>", "</u>")
        case .strikethrough: return Inline.toggle(text, selection, "~~", "~~")
        case .highlight: return Inline.toggle(text, selection, "==", "==")
        case .inlineCode: return Inline.toggle(text, selection, "`", "`")
        case .comment: return Inline.toggle(text, selection, "<!-- ", " -->")
        case .heading(let level): return Lines.heading(text, selection, level: min(max(level, 1), 6))
        case .paragraph: return Lines.heading(text, selection, level: 0)
        case .unorderedList: return Lines.unorderedList(text, selection, behavior)
        case .orderedList: return Lines.orderedList(text, selection)
        case .blockquote: return Lines.blockquote(text, selection)
        case .codeBlock: return Inline.codeBlock(text, selection)
        case .pageBreak: return Inline.pageBreak(text, selection)
        case .link: return Inline.link(text, selection, url: Self.url(in: clipboard), image: false)
        case .image: return Inline.link(text, selection, url: Self.url(in: clipboard), image: true)
        case .indent: return Lines.indent(text, selection, behavior)
        case .outdent: return Lines.outdent(text, selection, behavior)
        }
    }

    /// What Insert Page Break writes. Plain HTML that Typora, VS Code, Marked, md-to-pdf and most other Markdown tools turn into a
    /// page break, and that other renderers show as nothing; the renderer here also takes Pandoc's `\newpage` and Quarto's
    /// `{{< pagebreak >}}` (Web/src/render/plugins/page-break.ts).
    public static let pageBreakMarker = #"<div style="page-break-after: always"></div>"#

    /// `text` trimmed, if it is a single http(s)/ftp/mailto URL; nil otherwise.
    public static func url(in text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? trimmed : nil
        case "ftp": return url.host?.isEmpty == false ? trimmed : nil
        case "mailto": return trimmed.count > "mailto:".count ? trimmed : nil
        default: return nil
        }
    }
}

// MARK: - Inline wrapping, code block, link/image

enum Inline {
    /// Wrap the selection in `open`/`close`, or unwrap it when it is already wrapped (markers inside or just outside
    /// the selection). Whitespace at the selection's ends stays outside the markers (`** x**` would not render).
    // lazy: `***x***` + italic wraps again (`*****x*****`) instead of peeling one star; no markdown parse here.
    static func toggle(_ text: NSString, _ sel: NSRange, _ open: String, _ close: String) -> TextEdit {
        let o = open.utf16.count, c = close.utf16.count
        let marker = open.utf16.first!
        let single = open == close && o == 1
        func has(_ s: String, at location: Int) -> Bool {
            let n = s.utf16.count
            return location >= 0 && location + n <= text.length && text.substring(with: NSRange(location: location, length: n)) == s
        }
        func unit(_ i: Int) -> unichar? { i >= 0 && i < text.length ? text.character(at: i) : nil }

        var start = sel.location, end = NSMaxRange(sel)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        if start == end { start = sel.location; end = start }  // nothing but whitespace selected: act as a caret
        let core = NSRange(location: start, length: end - start)

        if core.length == 0 {
            if has(open, at: start - o), has(close, at: start), !(single && (unit(start - o - 1) == marker || unit(start + c) == marker)) {
                return TextEdit(range: NSRange(location: start - o, length: o + c), replacement: "", selection: NSRange(location: start - o, length: 0))
            }
            return TextEdit(range: core, replacement: open + close, selection: NSRange(location: start + o, length: 0))
        }
        // Markers inside the selection.
        if core.length >= o + c, has(open, at: start), has(close, at: end - c), !(single && unit(start + 1) == marker) {
            let inner = NSRange(location: start + o, length: core.length - o - c)
            return TextEdit(range: core, replacement: text.substring(with: inner), selection: NSRange(location: start, length: inner.length))
        }
        // Markers just outside it. A doubled single marker (`**x**` for italic) belongs to the stronger style.
        if has(open, at: start - o), has(close, at: end), !(single && (unit(start - o - 1) == marker || unit(end + c) == marker)) {
            return TextEdit(range: NSRange(location: start - o, length: core.length + o + c), replacement: text.substring(with: core), selection: NSRange(location: start - o, length: core.length))
        }
        return TextEdit(range: core, replacement: open + text.substring(with: core) + close, selection: NSRange(location: start + o, length: core.length))
    }

    /// Fenced block around the selection (or an empty one at the caret). Fences always start and end on their own
    /// lines; a trailing newline in the selection stays outside the block.
    static func codeBlock(_ text: NSString, _ sel: NSRange) -> TextEdit {
        let start = sel.location
        var end = NSMaxRange(sel)
        if sel.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        let body = text.substring(with: NSRange(location: start, length: end - start))
        var lineStart = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: start, length: 0))
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: end, length: 0))
        let lead = start == lineStart ? "" : "\n"
        let trail = end == contentsEnd ? "" : "\n"
        return TextEdit(
            range: NSRange(location: start, length: end - start),
            replacement: lead + "```\n" + body + "\n```" + trail,
            selection: NSRange(location: start + lead.utf16.count + 4, length: body.utf16.count)
        )
    }

    /// The page-break marker on a line of its own, below the line the selection ends on (replacing that line when it is blank),
    /// with a blank line on each side; the caret lands on the line after it.
    static func pageBreak(_ text: NSString, _ sel: NSRange) -> TextEdit {
        var end = NSMaxRange(sel)
        if sel.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }  // a selection of whole lines ends on their last one
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: end, length: 0))
        let blank = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)).allSatisfy { $0 == " " || $0 == "\t" }
        let range = blank ? NSRange(location: lineStart, length: contentsEnd - lineStart) : NSRange(location: contentsEnd, length: 0)
        var replacement = (blank ? "" : "\n\n") + MarkdownCommand.pageBreakMarker
        let hasNewline = lineEnd > contentsEnd
        if !hasNewline {
            replacement += "\n"  // the file ends here: end it with a newline
        } else if lineEnd < text.length {  // a following line that is not blank would touch the marker
            var nextEnd = 0, nextContentsEnd = 0
            text.getLineStart(nil, end: &nextEnd, contentsEnd: &nextContentsEnd, for: NSRange(location: lineEnd, length: 0))
            if !text.substring(with: NSRange(location: lineEnd, length: nextContentsEnd - lineEnd)).allSatisfy({ $0 == " " || $0 == "\t" }) { replacement += "\n" }
        }
        let newLength = text.length - range.length + (replacement as NSString).length
        let caret = min(range.location + (replacement as NSString).length + (hasNewline ? 1 : 0), newLength)
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// `[sel](url)` / `![sel](url)`. Caret lands where the user types next: the empty `[]`, the empty `()`, or after.
    static func link(_ text: NSString, _ sel: NSRange, url: String?, image: Bool) -> TextEdit {
        let bang = image ? "!" : ""
        let selected = text.substring(with: sel)
        let head = bang.utf16.count + 1  // `![` / `[`
        if url == nil, let own = MarkdownCommand.url(in: selected), own == selected {  // the selection is the URL
            return TextEdit(range: sel, replacement: "\(bang)[](\(selected))", selection: NSRange(location: sel.location + head, length: 0))
        }
        let target = url ?? ""
        let replacement = "\(bang)[\(selected)](\(target))"
        let caret: Int
        if selected.isEmpty { caret = sel.location + head }
        else if url != nil { caret = sel.location + replacement.utf16.count }
        else { caret = sel.location + head + sel.length + 2 }
        return TextEdit(range: sel, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }
}

@inline(__always) func isSpace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
