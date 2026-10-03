import Foundation

/// Which of the three `TextStats` numbers the status bar shows; a click steps to the next one.
public enum CountMode: String, CaseIterable, Sendable {
    case words, characters, charactersNoSpaces

    public var next: CountMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension TextStats {
    public func count(_ mode: CountMode) -> Int {
        switch mode {
        case .words: words
        case .characters: characters
        case .charactersNoSpaces: charactersNoSpaces
        }
    }

    /// Same rules as `textStats` in `Web/src/render/text.ts` (the whole-document numbers come from there); used for
    /// the editor selection, which has no render pass. `StatsParityTests` keeps the two in step.
    /// Han/kana count one word per character, other scripts one per run of letters/digits/marks (apostrophes join),
    /// characters are grapheme clusters minus line feeds, and "no spaces" also drops whitespace-only clusters.
    public init(counting text: String) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let cjk = Self.cjk.numberOfMatches(in: text, range: whole)
        let latinText = Self.cjk.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
        let latin = Self.word.numberOfMatches(in: latinText, range: NSRange(location: 0, length: (latinText as NSString).length))
        var characters = 0, noSpaces = 0
        for character in text where character != "\n" {
            characters += 1
            if !character.unicodeScalars.allSatisfy({ Self.jsWhitespace.contains($0.value) }) { noSpaces += 1 }
        }
        self.init(words: cjk + latin, characters: characters, charactersNoSpaces: noSpaces)
    }

    // NSRegularExpression is ICU, so these are the same patterns as the JS side.
    private static let cjk = try! NSRegularExpression(pattern: #"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}々ー]"#)
    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}\p{M}]+(?:['’][\p{L}\p{N}\p{M}]+)*"#)
    // ECMAScript `\s`; ICU's differs at U+0085 and U+FEFF.
    private static let jsWhitespace = Set<UInt32>(
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] + Array(0x2000...0x200A)
    )
}

extension [OutlineItem] {
    /// Index of the section the 0-based `line` belongs to: the last heading at or above it; nil before the first one.
    public func currentIndex(forLine line: Int) -> Int? {
        indices.last(where: { self[$0].line <= line })
    }
}
