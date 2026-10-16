import Foundation

/// Runs the last submitted action once `delay` has passed without a newer one. The sidebar uses it to follow the active
/// document: flicking through tabs with Ctrl-Tab must not re-point the "current location" tree on every step.
@MainActor
public final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration) { self.delay = delay }

    /// - Parameter delay: this time's wait instead of the one given to `init`.
    public func submit(after delay: Duration? = nil, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [delay = delay ?? self.delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
