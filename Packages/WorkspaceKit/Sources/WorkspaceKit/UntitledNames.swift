import Foundation

/// Names of untitled documents: "Untitled", "Untitled 2", "Untitled 3"…, and the file name the first save suggests.
public enum UntitledNames {
    public static func title(_ number: Int) -> String { number <= 1 ? "Untitled" : "Untitled \(number)" }

    /// The smallest number not in use, starting at 1 (a closed "Untitled 2" gives its name to the next new document).
    public static func firstFree(taken: Set<Int>) -> Int {
        var n = 1
        while taken.contains(n) { n += 1 }
        return n
    }

    /// The number in "Untitled 3" (1 for plain "Untitled"); nil for any other title.
    public static func number(of title: String) -> Int? {
        if title == "Untitled" { return 1 }
        guard title.hasPrefix("Untitled "), let n = Int(title.dropFirst("Untitled ".count)), n >= 2 else { return nil }
        return n
    }

    /// First save's suggested file name: the first heading of the text as "<heading>.md", else "Untitled.md". Headings inside
    /// fenced code blocks and a leading front-matter block do not count.
    // lazy: ATX headings only ("# Title"); Setext (underlined) headings are not recognised
    public static func suggestedFileName(for markdown: String) -> String {
        "\(heading(in: markdown).flatMap(fileSafe) ?? "Untitled").md"
    }

    static func heading(in markdown: String) -> String? {
        var fence: Character?
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }[...]
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) { lines = lines[(end + 1)...] }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.hasPrefix(String(repeating: marker, count: 3)) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil, line.hasPrefix("#"), !line.hasPrefix("#!") else { continue }
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count) else { continue }
            let rest = line.dropFirst(hashes.count)
            guard rest.first == " " || rest.first == "\t" else { continue }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }  // closing hashes of "## Title ##"
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Strips Markdown decoration and what a file name cannot hold; nil when nothing is left.
    static func fileSafe(_ heading: String) -> String? {
        var s = heading.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:\0".unicodeScalars.contains($0) }.map(Character.init))
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? nil : s
    }
}
