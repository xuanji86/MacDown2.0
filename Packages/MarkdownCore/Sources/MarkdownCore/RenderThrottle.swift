import Foundation

/// When to render the preview after the text changed. Leading edge: if no render started within the current interval (a pause
/// in typing), render at once, so the first keystroke is not made to wait. Trailing edge: inside the interval, wait for it to
/// end, so a typing burst renders about once per interval with the latest text. The interval follows what renders cost
/// (twice a moving average of recent ones, 16 ms to 300 ms): a small document is refreshed about every frame, a heavy one
/// is not fed renders faster than it finishes them. Pure: the caller keeps the clock, the pending text and the one render in
/// flight, and renders that text however late `delay` says; nothing here can drop it.
public struct RenderThrottle: Sendable {
    public static let minInterval = Duration.milliseconds(16)
    public static let maxInterval = Duration.milliseconds(300)
    private static let smoothing = 0.3  // weight of the newest render in the average

    private var lastRender: ContinuousClock.Instant?
    private var cost: Duration?  // moving average of the renders measured so far
    private let assumedCost: Duration

    /// `assumedCost` stands in until a render has been measured.
    public init(assumedCost: Duration = .milliseconds(75)) { self.assumedCost = assumedCost }

    /// Time between renders while text keeps changing.
    public var interval: Duration { min(Self.maxInterval, max(Self.minInterval, (cost ?? assumedCost) * 2)) }

    /// How long text that changed at `now` waits before it is rendered; `.zero` = render now.
    public func delay(at now: ContinuousClock.Instant) -> Duration {
        guard let lastRender else { return .zero }
        return max(.zero, lastRender + interval - now)
    }

    /// A render started at `now`.
    public mutating func rendered(at now: ContinuousClock.Instant) { lastRender = now }

    /// A render took `elapsed`. The first one is taken as is; later ones are averaged in.
    public mutating func finished(taking elapsed: Duration) {
        cost = cost.map { $0 + (elapsed - $0) * Self.smoothing } ?? elapsed
    }
}
