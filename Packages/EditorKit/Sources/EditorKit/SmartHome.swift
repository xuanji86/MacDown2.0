import Foundation

/// ⌘← with smart Home: first stop is the first non-blank character of the line, second stop the real line start.
enum SmartHome {
    /// UTF-16 offset to move the caret to from `caret`, using the logical line (up to "\n") that holds it.
    static func target(in text: NSString, caret: Int) -> Int {
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(caret, text.length), length: 0))
        var firstNonBlank = start
        while firstNonBlank < contentsEnd, [0x20, 0x09].contains(text.character(at: firstNonBlank)) { firstNonBlank += 1 }
        return caret == firstNonBlank ? start : firstNonBlank
    }

    /// Start of the logical line holding `caret`.
    static func lineStart(in text: NSString, caret: Int) -> Int {
        var start = 0
        text.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: min(caret, text.length), length: 0))
        return start
    }
}
