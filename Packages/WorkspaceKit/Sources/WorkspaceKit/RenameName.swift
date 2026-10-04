import Foundation

/// What a typed new file name means: the tab's inline editor, File > Rename… and the sidebar all take the stem the user
/// types and keep the extension the file already has (`.md`, `.qmd`…) when the typed name has none of its own.
public enum RenameName {
    /// Whether the text after the last dot is a file extension (letters/digits, not purely digits, no spaces): "notes.txt" has
    /// one; "v1.2", "Dr. Smith" and "draft." do not.
    public static func hasExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 12 && !ext.allSatisfy(\.isNumber) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The name to rename `current` to when the user typed `typed`: trimmed, and with `current`'s extension added when `typed` has
    /// none. "" when nothing was typed. A caller treats "" and a result equal to `current` as "no change".
    public static func normalized(typed: String, current: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }  // "notes." -> "notes" (then the extension below)
        guard !name.isEmpty else { return "" }
        let ext = (current as NSString).pathExtension
        return hasExtension(name) || ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// What the popover's Name field means: the field as it was shown means the file's exact current name (a name like `v1.2` or
    /// one with a leading space must not be "tidied" by merely opening the popover); an edited field is normalized.
    /// - Parameters: `shown` is the text the field started with; `current` the file's name, extension included.
    public static func resolved(typed: String, shown: String, current: String) -> String {
        typed == shown ? current : normalized(typed: typed, current: current)
    }

    /// Where the selection of the inline editor ends: the stem of the name is selected, not its extension.
    public static func stemEnd(in name: String) -> String.Index {
        guard hasExtension(name), let dot = name.lastIndex(of: ".") else { return name.endIndex }
        return dot
    }
}
