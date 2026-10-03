import Foundation
import Testing
@testable import EditorKit

/// Deterministic generator so a failing edit sequence can be replayed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct IncrementalTests {
    static let seed = "# Title\n\nSome *text* here with `code`.\n\n- a\n- b\n\n> quote\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nend 中文 😀\n"
    static let snippets = ["*", "**", "`", "\n\n", "\n", "# ", "> ", "- ", "```\n", "text ", "[a](b)", "~~", "| x | y |\n|-|-|\n", "中文", "😀", " ", "_", "    "]

    /// After every random edit, the incrementally maintained tree must style the document exactly like a fresh parse.
    /// This is what proves the edit points handed to tree-sitter (rows/columns) are right.
    @Test(arguments: [1, 2, 3, 4]) func incrementalParseMatchesFreshParse(seedValue: Int) async throws {
        var rng = SplitMix(state: UInt64(seedValue))
        let h = try await EngineHarness(Self.seed)
        for step in 0..<60 {
            let length = (h.text as NSString).length
            let location = Int.random(in: 0...length, using: &rng)
            let removed = Bool.random(using: &rng) ? 0 : Int.random(in: 0...min(6, length - location), using: &rng)
            let insert = Bool.random(using: &rng) ? "" : Self.snippets.randomElement(using: &rng)!
            // Never split a surrogate pair: the edit would not be valid text.
            let range = (h.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: removed))
            await h.replace(range, with: insert)

            let fresh = try await EngineHarness(h.text)
            let incremental = try await h.tokens()
            let expected = try await fresh.tokens()
            #expect(incremental == expected, "seed \(seedValue) step \(step): edit at \(location) -\(removed) +\(insert.debugDescription)")
            if incremental != expected { return }
        }
    }
}
