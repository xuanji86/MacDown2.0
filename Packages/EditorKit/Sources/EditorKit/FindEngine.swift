import Foundation

/// Pure search engine for finding matches and calculating replacements in a document string.
public enum FindEngine {
    /// Finds all matching ranges in `text`.
    /// - Returns: An array of NSRanges, and a boolean indicating whether regex compilation failed.
    public static func findMatches(
        in text: String,
        query: String,
        isRegex: Bool,
        isCaseSensitive: Bool
    ) -> (matches: [NSRange], invalidRegex: Bool) {
        guard !query.isEmpty, !text.isEmpty else { return ([], false) }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if isRegex {
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if !isCaseSensitive {
                options.insert(.caseInsensitive)
            }
            do {
                let regex = try NSRegularExpression(pattern: query, options: options)
                let results = regex.matches(in: text, options: [], range: fullRange)
                let ranges = results.map(\.range).filter { $0.length > 0 }
                return (ranges, false)
            } catch {
                return ([], true)
            }
        } else {
            let options: NSString.CompareOptions = isCaseSensitive ? [.literal] : [.caseInsensitive]
            var results: [NSRange] = []
            var searchRange = fullRange
            while searchRange.location < nsText.length {
                searchRange.length = nsText.length - searchRange.location
                let found = nsText.range(of: query, options: options, range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                results.append(found)
                searchRange.location = found.location + max(found.length, 1)
            }
            return (results, false)
        }
    }

    /// Calculates the replacement string for `range` in `text`.
    /// In regex mode, expands capture groups ($1, $2, etc.) and escape sequences (\n, \t, etc.);
    /// in plain mode, returns `replaceText` verbatim.
    public static func replacementString(
        for range: NSRange,
        in text: String,
        query: String,
        replaceText: String,
        isRegex: Bool,
        isCaseSensitive: Bool
    ) -> String {
        guard isRegex else { return replaceText }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: query, options: options),
              let match = regex.firstMatch(in: text, options: [], range: range) else {
            return replaceText
        }
        let template = unescapeRegexTemplate(replaceText)
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }

    /// Converts common escape sequences (\n, \t, \r) in replacement template to real control characters,
    /// while preserving escaped backslashes and escaped dollar signs for NSRegularExpression.
    public static func unescapeRegexTemplate(_ template: String) -> String {
        var result = ""
        result.reserveCapacity(template.count)
        var isEscaping = false
        for char in template {
            if isEscaping {
                switch char {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "r":
                    result.append("\r")
                case "\\":
                    result.append("\\\\")
                case "$":
                    result.append("\\$")
                default:
                    result.append("\\")
                    result.append(char)
                }
                isEscaping = false
            } else if char == "\\" {
                isEscaping = true
            } else {
                result.append(char)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
    }

    /// Finds the index in `matches` that is next after `currentLocation` (or `currentIndex + 1` if selection already matches).
    public static func nextIndex(
        in matches: [NSRange],
        currentLocation: Int,
        currentIndex: Int
    ) -> Int {
        guard !matches.isEmpty else { return 0 }
        if currentIndex >= 0, currentIndex < matches.count, matches[currentIndex].location == currentLocation {
            return (currentIndex + 1) % matches.count
        }
        if let idx = matches.firstIndex(where: { $0.location >= currentLocation }) {
            return idx
        }
        return 0
    }

    /// Finds the index in `matches` that is previous before `currentLocation` (or `currentIndex - 1` if selection already matches).
    public static func previousIndex(
        in matches: [NSRange],
        currentLocation: Int,
        currentIndex: Int
    ) -> Int {
        guard !matches.isEmpty else { return 0 }
        if currentIndex >= 0, currentIndex < matches.count, matches[currentIndex].location == currentLocation {
            return (currentIndex - 1 + matches.count) % matches.count
        }
        if let idx = matches.lastIndex(where: { $0.location < currentLocation }) {
            return idx
        }
        return matches.count - 1
    }
}
