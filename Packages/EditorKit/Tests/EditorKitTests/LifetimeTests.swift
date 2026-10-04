import AppKit
import Testing
@testable import EditorKit

/// A weak reference that can be asked "is it gone?" without keeping the object alive: reading a `weak` reference to an AppKit
/// object hands out an autoreleased strong one, which has to be drained before the answer means anything.
@MainActor
final class Watch {
    private weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
    var isFreed: Bool { autoreleasepool { object == nil } }

    /// Lets the main queue turn (Neon and the highlighter hop through it) until the object is gone or the time is up.
    func freed(within seconds: Double = 1) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !isFreed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return isFreed
    }
}

/// The editor view and its highlighter reference each other's world (the view owns the highlighter, which paints the view's
/// storage and asks it for marked text and the visible range): neither may keep the other alive.
@MainActor
struct LifetimeTests {
    @Test func theViewAndItsHighlighterAreFreedTogether() async throws {
        var view: Watch?, highlighter: Watch?
        autoreleasepool {
            let built = ViewTests.makeSizedView("# Title\n\nSome *text* here\n")
            built.setSelectedRange(NSRange(location: 3, length: 0))
            built.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            view = Watch(built)
            highlighter = built.highlighter.map(Watch.init)
        }
        #expect(highlighter != nil)
        #expect(try await highlighter?.freed() == true, "highlighter freed")
        #expect(try await view?.freed() == true, "view freed")
    }
}
