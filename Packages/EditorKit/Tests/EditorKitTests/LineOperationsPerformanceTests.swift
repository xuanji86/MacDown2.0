import Foundation
import Testing
@testable import EditorKit

/// Formatting every line of a big document must stay linear: the replacement text is assembled line by line, and the
/// bookkeeping (where each new line starts, how long the result is) must not rescan the text built so far (a UTF-16 count of a
/// non-ASCII Swift string is a scan).
struct LineOperationsPerformanceTests {
    /// `lines` lines of CJK text with a couple of ASCII marks: about 14 UTF-16 units each.
    private static func document(lines: Int) -> String {
        (0..<lines).map { "中文段落第\($0)行内容" }.joined(separator: "\n")
    }

    private func elapsed(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return clock.measure(body)
    }

    @Test func indentingAllOfALargeCJKDocumentIsLinear() throws {
        let text = Self.document(lines: 75_000) as NSString  // ~1 MB of UTF-16
        let all = NSRange(location: 0, length: text.length)
        var edit: TextEdit?
        let time = elapsed { edit = Lines.indent(text, all, EditorBehavior()) }
        let result = try #require(edit)
        // Same bytes out as in, plus one indent unit per line, and the selection still spans the whole region.
        let unit = Lines.indentUnit(EditorBehavior()).utf16.count
        #expect(result.replacement.utf16.count == text.length + 75_000 * unit)
        #expect(result.range == all)
        #expect(result.selection.length == result.replacement.utf16.count)
        // Linear is tens of milliseconds even unoptimised; the quadratic version took 24 s for 0.6 MB.
        #expect(time < .seconds(10), "took \(time)")
    }
}
