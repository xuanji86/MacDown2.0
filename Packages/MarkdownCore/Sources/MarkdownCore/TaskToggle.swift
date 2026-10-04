import Foundation

/// Checking a task-list box in the preview: which single character of the source to change.
///
/// Works on the document's LF text (what the editor holds; `MarkdownFile` restores CRLF / CR and the encoding on save),
/// with UTF-16 offsets so the result can go straight into an `NSTextView`. The edit is the one character between the
/// brackets of `[ ]` / `[x]`, nothing else, so the file's bytes stay as they were everywhere else.
///
/// Which lines are task items, and where the box sits in them, is the renderer's call, not this type's: `RenderResult.tasks` lists
/// them for the text the page shows with the line and column of each `[ ]`, so fences, front matter, indented code, lists inside
/// quotes, footnote definitions and every option that changes block structure are already accounted for, and there is no second
/// Markdown parser here to disagree with it. This only checks that the place the renderer named still looks like a mark (so a
/// stale or wrong `TaskItem` cannot edit anything else).
public enum TaskToggle {
    public struct Edit: Equatable, Sendable {
        /// The mark inside the brackets: always one UTF-16 unit.
        public let range: NSRange
        /// `"x"` to check, `" "` to uncheck.
        public let replacement: String
    }

    /// The edit that makes `task` (from the render of exactly `text`) `checked`, or nil when `text` has no such place, it does not
    /// hold a `[ ]` / `[x]` / `[X]` mark, or the box is already in that state.
    public static func edit(in text: String, task: TaskItem, checked: Bool) -> Edit? {
        guard task.mark >= 0, task.column >= 0 else { return nil }
        let u = Array(text.utf16)
        var start = 0
        for _ in 0..<task.mark {  // start of line `mark`
            guard let nl = u[start...].firstIndex(of: 0x0A) else { return nil }
            start = nl + 1
        }
        let end = u[start...].firstIndex(of: 0x0A) ?? u.count
        let p = start + task.column
        guard p + 2 < end, u[p] == 0x5B, u[p + 2] == 0x5D else { return nil }
        let isChecked: Bool
        switch u[p + 1] {
        case 0x78, 0x58: isChecked = true  // x X
        case 0x20, 0xA0: isChecked = false  // space, no-break space
        default: return nil
        }
        guard isChecked != checked else { return nil }
        return Edit(range: NSRange(location: p + 1, length: 1), replacement: checked ? "x" : " ")
    }
}
