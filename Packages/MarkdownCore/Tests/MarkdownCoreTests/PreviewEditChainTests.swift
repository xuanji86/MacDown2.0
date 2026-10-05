import Foundation
import Testing
@testable import MarkdownCore

/// The app's half of the preview editing protocol (Web/src/preview/editing.ts is the page's): an edit is applied only to exactly the
/// text the page made it on, in order, and a render carries the mark of the last edit it contains.
@Suite struct PreviewEditChainTests {
    /// Edit `seq` of burst `burst` (on render `base`) as the page sends it for `text`: what it removes and the source around it come
    /// from that text.
    private func edit(_ burst: Int, _ base: Int, _ seq: Int, _ location: Int, _ length: Int, _ replacement: String, in text: String) -> PreviewEdit {
        let ns = text as NSString
        let before = max(0, location - 16), after = min(ns.length, location + length + 16)
        return PreviewEdit(
            burst: burst, base: base, seq: seq, range: NSRange(location: location, length: length), replacement: replacement,
            removed: ns.substring(with: NSRange(location: location, length: length)),
            before: ns.substring(with: NSRange(location: before, length: location - before)),
            after: ns.substring(with: NSRange(location: location + length, length: after - location - length)),
            startsStep: false)
    }

    private func applying(_ e: PreviewEdit, to text: String) -> String { (text as NSString).replacingCharacters(in: e.range, with: e.replacement) }

    @Test func aBurstAppliesInOrderOnTheRenderItStartedFrom() throws {
        var chain = PreviewEditChain()
        chain.sent(version: 7, text: "hello world")
        let first = edit(1, 7, 1, 5, 0, "X", in: "hello world")
        #expect(try chain.expectedText(for: first).get() == "hello world")
        #expect(PreviewEditChain.fits(first, in: "hello world"))
        let one = applying(first, to: "hello world")
        chain.accept(first, result: one)
        #expect(chain.mark(for: one)! == (1, 1))
        let second = edit(1, 7, 2, 6, 0, "Y", in: one)
        #expect(try chain.expectedText(for: second).get() == one)
        let two = applying(second, to: one)
        chain.accept(second, result: two)
        #expect(chain.mark(for: two)! == (1, 2))
        // a render of the text edit 1 produced, sent late: still marked, the page holds it back
        #expect(chain.mark(for: one)! == (1, 1))
        #expect(chain.mark(for: "something else") == nil)
    }

    /// The page can report an edit made on a render before the app's call that sent it has returned (its message comes first): the
    /// render was sent, so its text is known.
    @Test func anEditOnARenderWhoseCallHasNotReturnedYetIsAccepted() throws {
        var chain = PreviewEditChain()
        chain.sent(version: 1, text: "a")
        chain.landed(version: 1, mark: nil)
        chain.sent(version: 2, text: "ab")  // not landed yet as far as the app knows
        #expect(chain.displayed! == (1, "a"))
        let e = edit(1, 2, 1, 2, 0, "c", in: "ab")
        #expect(try chain.expectedText(for: e).get() == "ab")
        #expect(throws: PreviewEditRefusal.self) { try chain.expectedText(for: edit(1, 3, 1, 0, 0, "c", in: "ab")).get() }  // never sent
    }

    @Test func gapsOtherBurstsAndNewlinesAreRefused() {
        var chain = PreviewEditChain()
        chain.sent(version: 3, text: "abc")
        #expect(throws: PreviewEditRefusal.stale) { try chain.expectedText(for: edit(1, 3, 2, 0, 0, "x", in: "abc")).get() }  // edit 1 never came
        chain.accept(edit(1, 3, 1, 0, 0, "x", in: "abc"), result: "xabc")
        #expect(throws: PreviewEditRefusal.stale) { try chain.expectedText(for: edit(1, 3, 3, 0, 0, "y", in: "xabc")).get() }  // edit 2 skipped
        #expect(throws: PreviewEditRefusal.stale) { try chain.expectedText(for: edit(2, 3, 2, 0, 0, "y", in: "xabc")).get() }  // another burst, same render
        for nl in ["a\nb", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            #expect(throws: PreviewEditRefusal.newline) { try chain.expectedText(for: edit(1, 3, 2, 1, 0, nl, in: "xabc")).get() }
        }
    }

    /// Bursts are told apart by the page's own number, not by the render they started on: two bursts can start on the same one.
    @Test func aLateRefusalOfAnEarlierBurstLeavesTheCurrentOneAlone() {
        var chain = PreviewEditChain()
        chain.sent(version: 5, text: "abc")
        chain.accept(edit(4, 5, 1, 3, 0, "d", in: "abc"), result: "abcd")
        chain.refused(edit(3, 5, 2, 0, 0, "x", in: "abc"))  // burst 3, on the same render: over already
        #expect(chain.mark(for: "abcd")! == (4, 1))
        chain.refused(edit(4, 5, 2, 4, 0, "e", in: "abcd"))  // this burst's: it cannot go on
        #expect(chain.mark(for: "abcd") == nil)
    }

    /// A render on the page makes the ones before it unnecessary, and ends the burst whose last edit it carries; one carrying an
    /// earlier edit, or another burst's, does not.
    @Test func aLandedRenderDropsOlderRendersAndEndsTheBurstItCompletes() throws {
        var chain = PreviewEditChain()
        for v in 1...3 { chain.sent(version: v, text: "t\(v)") }
        chain.accept(edit(1, 3, 1, 2, 0, "x", in: "t3"), result: "t3x")
        chain.accept(edit(1, 3, 2, 3, 0, "y", in: "t3x"), result: "t3xy")
        chain.sent(version: 4, text: "t3x")
        chain.landed(version: 4, mark: (1, 1))  // held back by the page? no: landed, but only up to edit 1
        #expect(chain.text(ofRender: 3) == nil && chain.text(ofRender: 4) == "t3x")
        #expect(chain.burst == 1 && chain.seq == 2)
        chain.sent(version: 5, text: "t3xy")
        chain.landed(version: 5, mark: (2, 2))  // another burst's mark: nothing of this one
        #expect(chain.burst == 1)
        chain.landed(version: 5, mark: (1, 2))
        #expect(chain.burst == nil && chain.mark(for: "t3xy") == nil)
        #expect(chain.displayed! == (5, "t3xy"))
        #expect(try chain.expectedText(for: edit(2, 5, 1, 0, 0, "z", in: "t3xy")).get() == "t3xy")  // the next burst starts on it
    }

    @Test func anEditMustFitTheText() {
        let text = "a😀b"  // 😀 is two UTF-16 units at 1..<3
        #expect(PreviewEditChain.fits(edit(1, 1, 1, 1, 2, "", in: text), in: text))
        #expect(!PreviewEditChain.fits(edit(1, 1, 1, 2, 0, "x", in: text), in: text))  // between the halves
        #expect(!PreviewEditChain.fits(edit(1, 1, 1, 1, 1, "", in: text), in: text))
        // the right length, other characters at the place: a shifted offset is caught
        let e = edit(1, 1, 1, 1, 0, "x", in: "hello")
        #expect(PreviewEditChain.fits(e, in: "hello"))
        #expect(!PreviewEditChain.fits(e, in: "jello"))
        #expect(!PreviewEditChain.fits(edit(1, 1, 1, 1, 1, "", in: "hello"), in: "hallo"))
        #expect(!PreviewEditChain.fits(edit(1, 1, 1, 4, 2, "", in: "hello!"), in: "hello"))  // past the end
    }

    @Test func identityIsByUTF16NotCanonicalEquivalence() {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed)  // Swift's ==
        #expect(!composed.isIdentical(to: decomposed))
        #expect(composed.isIdentical(to: "caf\u{E9}"))
        #expect("".isIdentical(to: ""))
        // bridged from AppKit (a text view's string) against native: same answer
        let bridged = NSMutableString(string: "caf\u{E9} 😀") as String
        #expect(bridged.isIdentical(to: "caf\u{E9} 😀"))
        #expect(!bridged.isIdentical(to: "cafe\u{301} 😀"))
        #expect(!bridged.isIdentical(to: "caf\u{E9} 😁"))
        var chain = PreviewEditChain()
        chain.sent(version: 1, text: composed)
        chain.accept(edit(1, 1, 1, 4, 0, "!", in: composed), result: composed + "!")
        #expect(chain.mark(for: decomposed + "!") == nil)
    }
}
