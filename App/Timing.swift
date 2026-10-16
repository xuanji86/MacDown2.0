import AppKit

extension Duration {
    /// One refresh interval of the main screen (8 ms at 120 Hz); ~16 ms when it is unknown. What the panes wait for to coalesce
    /// the changes of one frame into one delivery.
    @MainActor static var displayFrame: Duration {
        let seconds = NSScreen.main?.minimumRefreshInterval ?? 0
        return .seconds(seconds > 0 ? seconds : 1.0 / 60)
    }
}
