import Foundation

/// Bookkeeping for the sidebar's background directory reads: at most one read per directory in flight. A change that
/// arrives while a read runs cannot be trusted to be in its result, so it marks the directory dirty and one more read
/// follows. Results therefore never overlap or finish out of order, and a stale listing is replaced by the next read
/// instead of staying (a change during a big folder's first read used to be lost).
///
/// `Done` is what to run once a read that began after the request has been installed (the sidebar's "then").
public struct ReadTracker<Done> {
    private struct State {
        var dirty = false
        var current: [Done] = []  // wanted by the read in flight
        var next: [Done] = []  // wanted by the follow-up read
    }

    private var states: [String: State] = [:]

    public init() {}

    public func isReading(_ key: String) -> Bool { states[key] != nil }

    /// true: no read was running, start one now. false: one is running; it is marked dirty and `finish` asks for another.
    public mutating func request(_ key: String, then: Done? = nil) -> Bool {
        if var state = states[key] {
            state.dirty = true
            if let then { state.next.append(then) }
            states[key] = state
            return false
        }
        states[key] = State(current: then.map { [$0] } ?? [])
        return true
    }

    /// The read in flight has been installed. `again`: a change arrived meanwhile, start another read (the tracker already
    /// treats it as in flight). `done`: what the finished read owed its requesters.
    public mutating func finish(_ key: String) -> (done: [Done], again: Bool) {
        guard var state = states[key] else { return ([], false) }
        let done = state.current
        guard state.dirty else {
            states[key] = nil
            return (done, false)
        }
        state = State(current: state.next)
        states[key] = state
        return (done, true)
    }

    /// Roots or options changed: whatever is in flight is obsolete (the model drops its results by generation).
    public mutating func reset() { states = [:] }
}
