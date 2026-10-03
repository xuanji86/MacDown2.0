import Foundation
@testable import EditorKit

/// Tests write text with the selection inline: `|` is a caret, `⟦…⟧` a selection. (Neither occurs in the fixtures.)
struct Marked {
    var text: String
    var selection: NSRange

    init(_ marked: String) {
        let ns = marked as NSString
        let open = ns.range(of: "⟦"), close = ns.range(of: "⟧")
        if open.location != NSNotFound, close.location != NSNotFound {
            let inner = ns.substring(with: NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
            text = ns.substring(to: open.location) + inner + ns.substring(from: NSMaxRange(close))
            selection = NSRange(location: open.location, length: (inner as NSString).length)
        } else {
            let caret = ns.range(of: "|")
            precondition(caret.location != NSNotFound, "no selection marker in \(marked)")
            text = ns.replacingCharacters(in: caret, with: "")
            selection = NSRange(location: caret.location, length: 0)
        }
    }

    /// Renders back: `|` for a caret, `⟦…⟧` for a selection.
    static func render(_ text: String, _ sel: NSRange) -> String {
        let ns = text as NSString
        if sel.length == 0 { return ns.replacingCharacters(in: sel, with: "|") }
        return ns.substring(to: sel.location) + "⟦" + ns.substring(with: sel) + "⟧" + ns.substring(from: NSMaxRange(sel))
    }

    /// The text and selection after `edit`.
    func applying(_ edit: TextEdit?) -> String? {
        guard let edit else { return nil }
        return Marked.render((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }
}

/// Result of a formatting command, as marked text; nil when the command changes nothing.
func run(_ command: MarkdownCommand, _ input: String, clipboard: String? = nil, behavior: EditorBehavior = .init()) -> String? {
    let m = Marked(input)
    return m.applying(command.edit(in: m.text as NSString, selection: m.selection, clipboard: clipboard, behavior: behavior))
}

enum Key { case typed(String), newline, tab, backtab, backspace }

/// Result of a keystroke handled by the assistant; nil when the text view would do its default thing.
func press(_ key: Key, _ input: String, behavior: EditorBehavior = .init()) -> String? {
    let m = Marked(input)
    let text = m.text as NSString
    let edit: TextEdit?
    switch key {
    case .typed(let s): edit = EditingAssistant.typed(s, in: text, selection: m.selection, behavior: behavior)
    case .newline: edit = EditingAssistant.newline(in: text, selection: m.selection, behavior: behavior)
    case .tab: edit = EditingAssistant.tab(in: text, selection: m.selection, behavior: behavior)
    case .backtab: edit = EditingAssistant.backtab(in: text, selection: m.selection, behavior: behavior)
    case .backspace: edit = EditingAssistant.backspace(in: text, selection: m.selection, behavior: behavior)
    }
    return m.applying(edit)
}
