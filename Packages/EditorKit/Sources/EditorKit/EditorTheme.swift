import AppKit

/// Attributes a token may carry (PLAN 4.3.2): colour, bold/italic traits, underline, strikethrough. Never the point size.
public struct TokenStyle {
    public var color: NSColor?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public init(color: NSColor? = nil, bold: Bool = false, italic: Bool = false, underline: Bool = false, strikethrough: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }
}

/// What a theme says about the system appearance (PLAN 4.5). `light` / `dark`: the colours are a light / dark palette and
/// AppKit draws its chrome (scroll bars, find bar) to match. `auto`: the palette is neutral and the chrome follows the system.
public enum ThemeAppearance: String, Codable, Sendable {
    case light, dark, auto
}

/// Everything the editor looks like, as plain values; decoded from the JSON theme format of PLAN 4.5 (see `init(json:)`).
/// Colours are fixed per theme: the editor does not follow the system appearance by itself (like the original MacDown,
/// the default is a dark editor next to a white preview). "Follow the system" is a choice between two themes, made by
/// `ThemeLibrary.resolve`.
// @unchecked: NSFont/NSColor are immutable in practice.
public struct EditorTheme: @unchecked Sendable {
    public var name: String
    public var appearance: ThemeAppearance
    /// Name of the theme that stands in for this one on the other system appearance ("Solarized Dark" <-> "Solarized Light").
    public var counterpart: String?
    public var font: NSFont
    public var background: NSColor
    public var text: NSColor
    public var caret: NSColor
    public var selection: NSColor
    public var lineNumber: NSColor
    public var currentLine: NSColor
    public var tokens: [TokenKind: TokenStyle]

    public init(
        name: String, appearance: ThemeAppearance, counterpart: String? = nil, font: NSFont, background: NSColor, text: NSColor,
        caret: NSColor, selection: NSColor, lineNumber: NSColor? = nil, currentLine: NSColor? = nil, tokens: [TokenKind: TokenStyle]
    ) {
        self.name = name
        self.appearance = appearance
        self.counterpart = counterpart
        self.font = font
        self.background = background
        self.text = text
        self.caret = caret
        self.selection = selection
        self.lineNumber = lineNumber ?? text.withAlphaComponent(0.5)
        self.currentLine = currentLine ?? text.withAlphaComponent(0.06)
        self.tokens = tokens
    }

    /// The chrome appearance to force on the editor; nil = follow the system (`auto`).
    public var chromeAppearance: NSAppearance? {
        switch appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .auto: nil
        }
    }

    /// The theme with the user's font choice: `name` empty or unknown = the system monospaced font. Sizes are clamped
    /// to what the editor can lay out sensibly.
    public func withFont(name: String, size: CGFloat) -> EditorTheme {
        var copy = self
        let size = min(max(size, 8), 72)
        copy.font = (name.isEmpty ? nil : NSFont(name: name, size: size)) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return copy
    }

    /// Attributes of unstyled text.
    var baseAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: text] }

    // MARK: Built-ins (Resources/Themes/*.json, listed in `ThemeLibrary`)

    /// The default (dark editor next to the white preview, like the original MacDown).
    public static let `default` = dark
    public static let dark = ThemeLibrary.builtIn(named: "Default Dark")
    public static let light = ThemeLibrary.builtIn(named: "Default Light")
}

// MARK: JSON

extension EditorTheme {
    /// PLAN 4.5 theme file:
    /// ```
    /// { "name": "…", "appearance": "light|dark|auto", "counterpart": "other-appearance theme (optional)",
    ///   "font": { "name": "…", "size": 13 },                       // optional; name absent = system monospaced
    ///   "colors": { "background", "text", "caret", "selection", "lineNumber", "currentLine" },   // "#RRGGBB" or "#RRGGBBAA"
    ///   "tokens": { "<TokenKind>": { "fg": "#RRGGBB", "bold": true, "italic": …, "underline": …, "strikethrough": … } } }
    /// ```
    /// `background` and `text` are required; the other colours default to values derived from them. Token keys are the raw
    /// values of `TokenKind`; unknown keys are ignored so a theme written for a newer app still loads.
    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        let font = file.font.flatMap { spec -> NSFont? in
            let size = spec.size ?? 13
            return spec.name.flatMap { NSFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        } ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = file.colors.text.color
        var tokens: [TokenKind: TokenStyle] = [:]
        for (key, spec) in file.tokens ?? [:] {
            guard let kind = TokenKind(rawValue: key) else { continue }
            tokens[kind] = TokenStyle(color: spec.fg?.color, bold: spec.bold ?? false, italic: spec.italic ?? false,
                                      underline: spec.underline ?? false, strikethrough: spec.strikethrough ?? false)
        }
        self.init(
            name: file.name, appearance: file.appearance, counterpart: file.counterpart, font: font,
            background: file.colors.background.color, text: text, caret: file.colors.caret?.color ?? text,
            selection: file.colors.selection?.color ?? text.withAlphaComponent(0.25),
            lineNumber: file.colors.lineNumber?.color, currentLine: file.colors.currentLine?.color, tokens: tokens)
    }

    private struct File: Decodable {
        struct Font: Decodable { var name: String?; var size: CGFloat? }
        struct Colors: Decodable {
            var background: Hex, text: Hex
            var caret: Hex?, selection: Hex?, lineNumber: Hex?, currentLine: Hex?
        }
        struct Token: Decodable { var fg: Hex?; var bold: Bool?; var italic: Bool?; var underline: Bool?; var strikethrough: Bool? }
        var name: String
        var appearance: ThemeAppearance
        var counterpart: String?
        var font: Font?
        var colors: Colors
        var tokens: [String: Token]?
    }

    /// "#RRGGBB" or "#RRGGBBAA"; anything else fails the whole theme with a message naming the value.
    private struct Hex: Decodable {
        let color: NSColor
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : ""
            guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "colour must be #RRGGBB or #RRGGBBAA, got \"\(raw)\""))
            }
            let (rgb, alpha) = digits.count == 6 ? (value, 255) : (value >> 8, value & 0xFF)
            color = NSColor(hex: Int(rgb), alpha: CGFloat(alpha) / 255)
        }
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
