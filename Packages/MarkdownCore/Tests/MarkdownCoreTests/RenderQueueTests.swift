import Foundation
import Testing

@testable import MarkdownCore

private final class Doc {}

@Test func aBurstRendersTheLatestTextOnceAndNeverDropsTheLast() {
    var q = RenderQueue()
    q.submit("a")
    let first = q.begin()
    #expect(first?.text == "a" && first?.version == 1)
    #expect(q.gap(afterRenderTaking: .milliseconds(80)) == nil)  // nothing waits: no pause
    q.submit("b")
    q.submit("c")  // while a renders
    #expect(q.gap(afterRenderTaking: .milliseconds(80)) == .milliseconds(80))  // as long as the render took
    let second = q.begin()
    #expect(second?.text == "c" && second?.version == 2)  // "b" is never rendered
    let drained = q.begin()
    #expect(drained == nil && q.latest == "c")
}

@Test func aDifferentDocumentStartsFromNothingAndTheSameOneKeepsItsText() {
    let (a, b) = (Doc(), Doc())
    var q = RenderQueue()
    let first = q.show(ObjectIdentifier(a))
    #expect(first)  // the first one
    q.submit("text of a")
    let old = q.begin()!
    q.submit("typed in a")
    let switched = q.show(ObjectIdentifier(b))
    #expect(switched)  // tab switch
    let leftover = q.begin()
    #expect(leftover == nil && q.latest == nil && q.displayed == nil)  // a's text is not rendered with b's settings
    let landedOld = q.landed(old, tasks: [])
    #expect(!landedOld)  // a's render still on its way is not b's
    #expect(q.displayed == nil)
    q.submit("text of b")
    let again = q.show(ObjectIdentifier(b))
    #expect(!again)  // same document (new folder, flavor): text stays
    let kept = q.begin()
    #expect(q.latest == "text of b" && kept?.text == "text of b")
    q.clear()
    let afterClear = q.begin()
    #expect(q.latest == nil && afterClear == nil)
    let reshown = q.show(ObjectIdentifier(b))
    #expect(reshown)  // after the window showed nothing, any document is new
}

@Test func aCheckboxClickIsMatchedToWhatThePageShowsNotToTheRenderOnItsWay() {
    let task = TaskItem(line: 0, mark: 0, column: 2)
    var q = RenderQueue()
    q.submit("- [ ] one")
    let t1 = q.begin()!
    #expect(q.toggleTarget(version: 1) == nil)  // not answered yet: refused
    q.landed(t1, tasks: [task])
    #expect(q.toggleTarget(version: 1)?.text == "- [ ] one" && q.toggleTarget(version: 1)?.tasks == [task])
    q.submit("- [ ] one\nmore")
    let t2 = q.begin()!  // render 2 started, the page still shows render 1
    #expect(q.toggleTarget(version: 1)?.text == "- [ ] one")  // a click on it still counts (the editor checks its text)
    #expect(q.toggleTarget(version: 2) == nil)
    q.landed(t2, tasks: [task])
    #expect(q.toggleTarget(version: 1) == nil && q.toggleTarget(version: 2)?.text == "- [ ] one\nmore")
    q.submit("x")
    q.landed(q.begin()!, tasks: nil)  // an answer the app could not read: nothing to toggle
    #expect(q.toggleTarget(version: 3) == nil)
    q.pageReloaded()
    #expect(q.displayed == nil)
}
