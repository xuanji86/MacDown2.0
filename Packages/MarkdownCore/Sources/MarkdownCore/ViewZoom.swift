import Foundation

/// View ▸ Zoom In / Zoom Out / Actual Size: one level for the editor font and the preview together (a multiplier on the
/// configured editor font size and on the preview page), global, kept in the app's preferences as a whole percent.
/// Pure so the steps and the limits are tested (`ViewZoomTests`).
public enum ViewZoom {
    public static let key = "view.zoomPercent"
    public static let actualSize = 100
    /// A browser's steps between 50 % and 300 %: each Zoom In / Zoom Out moves to the next one.
    public static let steps = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300]

    /// Whatever the preferences hold (a hand-edited 5000, 0, -3) reads as a level inside the range.
    public static func clamped(_ percent: Int) -> Int { min(max(percent, steps[0]), steps[steps.count - 1]) }

    /// The next step above `percent` (a level between steps included), the largest step at the top.
    public static func zoomedIn(from percent: Int) -> Int { steps.first { $0 > clamped(percent) } ?? steps[steps.count - 1] }

    /// The next step below `percent`, the smallest step at the bottom.
    public static func zoomedOut(from percent: Int) -> Int { steps.last { $0 < clamped(percent) } ?? steps[0] }

    public static func canZoomIn(from percent: Int) -> Bool { zoomedIn(from: percent) != clamped(percent) }
    public static func canZoomOut(from percent: Int) -> Bool { zoomedOut(from: percent) != clamped(percent) }

    /// The multiplier for a font size or a page.
    public static func factor(_ percent: Int) -> Double { Double(clamped(percent)) / 100 }
}
