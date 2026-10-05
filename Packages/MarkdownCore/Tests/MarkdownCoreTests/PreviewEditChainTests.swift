import Foundation
import Testing
@testable import MarkdownCore

/// The app's half of the preview editing protocol (Web/src/preview/editing.ts is the page's): an edit is applied only to exactly the
/// text the page made it on, in order, and a render carries the mark of the last edit it contains.
@Suite struct PreviewEditChainTests {
    private func edit(_ base: Int, _ seq: Int, _ location: Int, _ length: Int, _ text: String) -> PreviewEdit {
        PreviewEdit(base: base, seq: seq, range: NSRange(location: location, length: length), replacement: text)
    }

    @Test func aBurstAppliesInOrderOnTheRenderItStartedFrom() {
        var chain = PreviewEditChain()
        let shown = (version: 7, text: "hello world")
        let first = edit(7, 1, 5, 0, "X")
        #expect(chain.expectedText(for: first, displayed: shown) == "hello world")
        let one = PreviewEditChain.applying(first, to: "hello world")
        #expect(one == "helloX world")
        chain.accept(first, result: one)
        #expect(chain.mark(for: one)! == (7, 1))
        let second = edit(7, 2, 6, 0, "Y")
        #expect(chain.expectedText(for: second, displayed: shown) == one)
        chain.accept(second, result: PreviewEditChain.applying(second, to: one))
        #expect(chain.text == "helloXY world")
        #expect(chain.mark(for: "helloXY world")! == (7, 2))
        #expect(chain.mark(for: "helloX world") == nil)  // not the latest text: no mark
    }

    @Test func gapsOtherBurstsAndOtherRendersAreRefused() {
        var chain = PreviewEditChain()
        let shown = (version: 3, text: "abc")
        #expect(chain.expectedText(for: edit(2, 1, 0, 0, "x"), displayed: shown) == nil)  // made on an older render
        #expect(chain.expectedText(for: edit(3, 2, 0, 0, "x"), displayed: shown) == nil)  // edit 1 never arrived
        #expect(chain.expectedText(for: edit(3, 1, 0, 0, "x"), displayed: nil) == nil)  // nothing shown (a new page, a document switch)
        let first = edit(3, 1, 0, 0, "x")
        chain.accept(first, result: "xabc")
        #expect(chain.expectedText(for: edit(3, 3, 0, 0, "y"), displayed: shown) == nil)  // edit 2 skipped
        #expect(chain.expectedText(for: edit(4, 2, 0, 0, "y"), displayed: shown) == nil)  // another burst's edit 2
        // a new burst on a newer render starts over
        #expect(chain.expectedText(for: edit(5, 1, 0, 0, "y"), displayed: (version: 5, text: "xabc")) == "xabc")
        chain.reset()
        #expect(chain.mark(for: "xabc") == nil)
    }

    @Test func anEditMustFitTheText() {
        #expect(PreviewEditChain.isApplicable(edit(1, 1, 0, 3, ""), to: "abc"))
        #expect(!PreviewEditChain.isApplicable(edit(1, 1, 2, 2, ""), to: "abc"))  // past the end
        #expect(!PreviewEditChain.isApplicable(edit(1, 1, 1, 0, "a\nb"), to: "abc"))  // a line break is structure
        #expect(!PreviewEditChain.isApplicable(edit(1, 1, 1, 0, "a\u{2028}b"), to: "abc"))
        // "a😀b": 😀 is two UTF-16 units at 1..<3
        #expect(PreviewEditChain.isApplicable(edit(1, 1, 1, 2, ""), to: "a😀b"))
        #expect(!PreviewEditChain.isApplicable(edit(1, 1, 2, 0, "x"), to: "a😀b"))  // between the halves
        #expect(!PreviewEditChain.isApplicable(edit(1, 1, 1, 1, ""), to: "a😀b"))
        #expect(PreviewEditChain.applying(edit(1, 1, 1, 2, "中"), to: "a😀b") == "a中b")
    }
}
