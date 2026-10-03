import Foundation

/// The Markdown and Rendering settings pages (PLAN §4.8) as plain values, and their mapping to `RenderOptions`.
/// Only the user-facing switches live here; `flavor` / `renderChunks` come from extensions, not from settings.
/// Defaults are `RenderOptions()`'s, so there is one place that says what "default" means.
public struct RenderPreferences: Equatable, Sendable {
    public var extensions: Set<MarkdownExtension>
    public var hardBreaks: Bool
    public var allowRawHTML: Bool
    public var codeHighlighting: Bool
    public var codeLineNumbers: Bool
    public var inlineDollarMath: Bool
    public var frontMatterDisplay: FrontMatterDisplay

    public init() {
        let d = RenderOptions()
        extensions = d.extensions
        hardBreaks = d.hardBreaks
        allowRawHTML = d.allowRawHTML
        codeHighlighting = d.codeHighlighting
        codeLineNumbers = d.codeLineNumbers
        inlineDollarMath = d.inlineDollarMath
        frontMatterDisplay = d.frontMatterDisplay
    }

    /// The renderer's input: everything not covered by a setting keeps `RenderOptions`' default.
    public var options: RenderOptions {
        var o = RenderOptions()
        o.extensions = extensions
        o.hardBreaks = hardBreaks
        o.allowRawHTML = allowRawHTML
        o.codeHighlighting = codeHighlighting
        o.codeLineNumbers = codeLineNumbers
        o.inlineDollarMath = inlineDollarMath
        o.frontMatterDisplay = frontMatterDisplay
        return o
    }

    // MARK: Persistence

    /// UserDefaults keys. One key per switch, so `defaults read` stays legible and a missing key means "default".
    public enum Key {
        public static func ext(_ e: MarkdownExtension) -> String { "render.ext.\(e.rawValue)" }
        public static let hardBreaks = "render.hardBreaks"
        public static let allowRawHTML = "render.allowRawHTML"
        public static let codeHighlighting = "render.codeHighlighting"
        public static let codeLineNumbers = "render.codeLineNumbers"
        public static let inlineDollarMath = "render.inlineDollarMath"
        public static let frontMatterDisplay = "render.frontMatterDisplay"
    }

    /// A key that is absent or holds the wrong type reads as the default.
    public init(defaults: UserDefaults) {
        self.init()
        for e in MarkdownExtension.allCases {
            if let on = defaults.object(forKey: Key.ext(e)) as? Bool { if on { extensions.insert(e) } else { extensions.remove(e) } }
        }
        func bool(_ key: String, _ value: inout Bool) { if let b = defaults.object(forKey: key) as? Bool { value = b } }
        bool(Key.hardBreaks, &hardBreaks)
        bool(Key.allowRawHTML, &allowRawHTML)
        bool(Key.codeHighlighting, &codeHighlighting)
        bool(Key.codeLineNumbers, &codeLineNumbers)
        bool(Key.inlineDollarMath, &inlineDollarMath)
        if let raw = defaults.string(forKey: Key.frontMatterDisplay), let d = FrontMatterDisplay(rawValue: raw) { frontMatterDisplay = d }
    }

    /// Only values that differ from the default are stored, so a default that changes later reaches users who never touched it.
    public func write(to defaults: UserDefaults) {
        let d = RenderPreferences()
        func store<T: Equatable>(_ key: String, _ value: T, _ standard: T, as encode: (T) -> Any) {
            if value == standard { defaults.removeObject(forKey: key) } else { defaults.set(encode(value), forKey: key) }
        }
        for e in MarkdownExtension.allCases { store(Key.ext(e), extensions.contains(e), d.extensions.contains(e)) { $0 } }
        store(Key.hardBreaks, hardBreaks, d.hardBreaks) { $0 }
        store(Key.allowRawHTML, allowRawHTML, d.allowRawHTML) { $0 }
        store(Key.codeHighlighting, codeHighlighting, d.codeHighlighting) { $0 }
        store(Key.codeLineNumbers, codeLineNumbers, d.codeLineNumbers) { $0 }
        store(Key.inlineDollarMath, inlineDollarMath, d.inlineDollarMath) { $0 }
        store(Key.frontMatterDisplay, frontMatterDisplay, d.frontMatterDisplay) { $0.rawValue }
    }
}
