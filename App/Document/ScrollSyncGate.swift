import Foundation

/// Ping-pong guard for scroll sync (Foundation only so `Scripts/test-scroll-sync.sh` can compile it alone).
/// Whichever side scrolled first owns the sync for `window` seconds after its last accepted event; reports from the
/// other side in that span are echoes of our own programmatic scroll and are dropped.
struct ScrollSyncGate {
    enum Side { case editor, preview }

    var window: TimeInterval = 0.15
    private var origin: Side?
    private var until: TimeInterval = 0

    /// True when `side`'s report should drive the other pane; `now` is any monotonic clock in seconds.
    mutating func accept(_ side: Side, at now: TimeInterval) -> Bool {
        if let origin, origin != side, now < until { return false }
        origin = side
        until = now + window
        return true
    }
}
