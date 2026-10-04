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
    /// ⌘← goes to the first non-blank character before the real start of the line.
    public var smartHome = true

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
