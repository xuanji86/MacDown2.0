import Foundation
import Testing

@testable import MarkdownCore

@Test func renderOptionsJSONIsTheSameEveryTime() {
    var options = RenderOptions()
    options.files = ["a.qmd": "x", "b.qmd": "y", "c.qmd": "z"]
    let first = options.json
    #expect((0..<500).allSatisfy { _ in options.json == first })
    // An equal set built another way (other insertion order) must give the same string too.
    var other = RenderOptions()
    other.files = options.files
    other.extensions = []
    for e in MarkdownExtension.allCases.reversed() where options.extensions.contains(e) { other.extensions.insert(e) }
    #expect(other == options && other.json == first)
}

@Test func renderOptionsJSONStillDecodes() throws {
    var options = RenderOptions()
    options.hardBreaks = true
    options.files = ["a.qmd": "x"]
    #expect(try JSONDecoder().decode(RenderOptions.self, from: Data(options.json.utf8)) == options)
}

@Test func throttleRendersTheFirstChangeAfterAPauseAtOnce() {
    let t0 = ContinuousClock.now
    var throttle = RenderThrottle()
    #expect(throttle.delay(at: t0) == .zero)  // never rendered
    throttle.rendered(at: t0)
    throttle.finished(taking: .milliseconds(10))
    #expect(throttle.delay(at: t0 + throttle.interval) == .zero)  // idle for a full interval
    #expect(throttle.delay(at: t0 + .seconds(5)) == .zero)
}

@Test func throttleCoalescesABurstOntoTheTrailingEdge() {
    let t0 = ContinuousClock.now
    var throttle = RenderThrottle()
    throttle.rendered(at: t0)
    throttle.finished(taking: .milliseconds(40))  // interval 80 ms
    #expect(throttle.interval == .milliseconds(80))
    // Changes inside the interval all aim at the same moment: one render, of the latest text.
    for ms in [10, 40, 79] {
        let now = t0 + .milliseconds(ms)
        #expect(now + throttle.delay(at: now) == t0 + .milliseconds(80))
    }
    // That trailing render starts a new interval; the next change waits for it, never longer.
    throttle.rendered(at: t0 + .milliseconds(80))
    #expect(throttle.delay(at: t0 + .milliseconds(100)) == .milliseconds(60))
}

@Test func throttleIntervalFollowsRenderCostWithinBounds() {
    var throttle = RenderThrottle()
    #expect(throttle.interval == .milliseconds(150))  // before anything was measured
    throttle.rendered(at: .now)
    throttle.finished(taking: .milliseconds(1))
    #expect(throttle.interval == RenderThrottle.minInterval)  // tiny document: about a frame
    for _ in 0..<50 { throttle.finished(taking: .seconds(2)) }
    #expect(throttle.interval == RenderThrottle.maxInterval)  // huge one: capped
    for _ in 0..<50 { throttle.finished(taking: .milliseconds(30)) }
    #expect(abs((throttle.interval - .milliseconds(60)).components.attoseconds) < 1_000_000_000_000_000)  // average settles near 30 ms x 2
}
