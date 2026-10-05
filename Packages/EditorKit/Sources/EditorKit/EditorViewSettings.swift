import AppKit

/// What the Editor settings page controls beyond fonts and typing behaviour (`EditorBehavior`). The app keeps these in
/// `UserDefaults` under `Key`; `MarkdownTextView.apply(settings:)` makes the view follow a value of this type.
public struct EditorViewSettings: Equatable, Sendable {
    /// `UserDefaults` / `@AppStorage` keys.
    public enum Key {
        public static let lineNumbers = "editor.lineNumbers"
        public static let lineSpacing = "editor.lineSpacing"
        public static let limitWidth = "editor.limitWidth"
        public static let maxWidth = "editor.maxWidth"
        public static let showInvisibles = "editor.showInvisibles"
        public static let smartHome = "editor.smartHome"
        public static let scrollPastEnd = "editor.scrollPastEnd"
        // The system's text substitutions, one switch each (all off by default: this is source text).
        public static let smartQuotes = "editor.smartQuotes"
        public static let smartDashes = "editor.smartDashes"
        public static let textReplacement = "editor.textReplacement"
        public static let spellingCorrection = "editor.spellingCorrection"
        public static let smartInsertDelete = "editor.smartInsertDelete"
    }

    public static let lineSpacingRange: ClosedRange<CGFloat> = 0...12
    public static let maxWidthRange: ClosedRange<CGFloat> = 400...1600

    public var showsLineNumbers = false
    /// Extra points between lines (`NSParagraphStyle.lineSpacing`); 3 is the original MacDown's default.
    public var lineSpacing: CGFloat = 3
    /// Centre the text in a column of `maxWidth` points instead of filling the view.
    public var limitsWidth = false
    public var maxWidth: CGFloat = 760
    /// Draw a mark for every space, tab and line end.
    public var showsInvisibles = false
    /// The document scrolls half a window past its last line, so the last line can sit mid-window (off, like the original MacDown).
    public var scrollsPastEnd = false
    /// ⌘← goes to the first non-blank character before the real start of the line.
    public var smartHome = true

    // MARK: System text substitutions (all off: they rewrite what the user typed, and Markdown source must stay as typed)

    /// "straight" quotes become curly ones.
    public var smartQuotes = false
    /// `--` becomes an en/em dash.
    public var smartDashes = false
    /// The user's System Settings > Keyboard > Text Replacements (also the double-space period).
    public var textReplacement = false
    /// Automatic spelling correction. macOS has no per-view switch for "capitalize words automatically": it is part of the same
    /// correction pass, so this one switch governs both.
    public var spellingCorrection = false
    /// Adds or removes spaces around pasted, cut or double-click-selected words.
    public var smartInsertDelete = false

    public init() {}

    /// The values the view actually uses: out-of-range input (hand-edited defaults) is clamped, not rejected.
    var clamped: EditorViewSettings {
        var s = self
        s.lineSpacing = min(max(lineSpacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        s.maxWidth = min(max(maxWidth, Self.maxWidthRange.lowerBound), Self.maxWidthRange.upperBound)
        return s
    }

    /// Side inset of the text for a view `viewWidth` wide: `minimum`, or whatever centres a `maxWidth` column.
    static func horizontalInset(viewWidth: CGFloat, maxWidth: CGFloat?, minimum: CGFloat = 15) -> CGFloat {
        guard let maxWidth else { return minimum }
        return max(minimum, ((viewWidth - maxWidth) / 2).rounded(.up))  // up: the column is never wider than asked
    }
}
