import Foundation

/// `{{< include file.qmd >}}` support, Swift half. The preview and export renderers cannot read files, so before each
/// render the app asks `files(for:readFile:)` which files the document can reach and hands their text over as
/// `RenderOptions.files`; `Web/src/quarto/rules/include.ts` then inlines them. That rule enforces the limits itself
/// (inside the document folder, 5 levels, no cycles); this side only has to find the same paths and stop. The path rules
/// in `resolve` mirror `resolveInclude` there; keep the two in step.
public enum QuartoIncludes {
    /// Include nesting the renderer allows: the document includes level 1, which includes level 2, ... up to level 5.
    public static let maxDepth = 5
    /// lazy: 64 files per render; a document with more shows "not found" for the rest. Raise it, or read lazily per level.
    public static let maxFiles = 64

    private static let include = try! NSRegularExpression(
        pattern: #"^ {0,3}\{\{<[ \t]*include[ \t]+(?:"([^"]+)"|'([^']+)'|(\S+?))[ \t]*>\}\}[ \t]*$"#, options: [.anchorsMatchLines])

    /// Path of an include `target` relative to the document folder, given the folder of the file that contains the
    /// include (`""` = the document folder). nil: absolute, a URL, or it leaves the document folder.
    public static func resolve(_ target: String, from directory: String) -> String? {
        if target.hasPrefix("/") || target.contains("\0") || target.contains("\\") { return nil }
        if target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for segment in target.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                if parts.isEmpty { return nil }
                parts.removeLast()
            } else {
                parts.append(String(segment))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The include targets written in `text`, in order.
    static func targets(in text: String) -> [String] {
        guard text.contains("{{<") else { return [] }  // the common case, without a regex pass
        let ns = text as NSString
        return include.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0) }
        }
    }

    /// Every file reachable from `markdown` through includes, by document-relative path. `readFile` returns the text of
    /// such a path or nil (missing, not a regular file, outside the folder, too big); it is asked once per path.
    public static func files(for markdown: String, readFile: (String) -> String?) -> [String: String] {
        var found: [String: String] = [:]
        var asked: Set<String> = []
        var queue: [(text: String, directory: String, level: Int)] = [(markdown, "", 0)]
        var next = 0
        while next < queue.count {
            let (text, directory, level) = queue[next]
            next += 1
            guard level < maxDepth else { continue }
            for target in targets(in: text) {
                guard let path = resolve(target, from: directory), asked.insert(path).inserted, found.count < maxFiles,
                      let content = readFile(path) else { continue }
                found[path] = content
                queue.append((content, path.split(separator: "/").dropLast().joined(separator: "/"), level + 1))
            }
        }
        return found
    }
}
