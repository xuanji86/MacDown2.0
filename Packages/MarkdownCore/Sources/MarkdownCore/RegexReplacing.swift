import Foundation

extension NSRegularExpression {
    /// Replaces every match with what `transform` returns for it; the closure gets the match and its capture groups (`[0]` is the whole
    /// match, a group that did not take part is ""). Works on UTF-16 ranges, so a match next to a combining mark is no problem.
    func replacingMatches(in text: String, with transform: ([String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) })
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
