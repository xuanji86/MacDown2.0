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

/// Everything the editor looks like, as plain values (the shape PLAN 4.5's JSON theme library will decode into).
/// Colours are fixed per theme: the editor does not follow the system appearance (like the original MacDown, the
/// default is a dark editor next to a white preview). `appearance` only tells AppKit which chrome (scroll bars,
/// find bar) to draw around it.
// @unchecked: NSFont/NSColor are immutable in practice.
public struct EditorTheme: @unchecked Sendable {
    public var name: String
    public var appearance: NSAppearance.Name
    public var font: NSFont
    public var background: NSColor
    public var text: NSColor
    public var caret: NSColor
    public var selection: NSColor
    public var tokens: [TokenKind: TokenStyle]

    public init(name: String, appearance: NSAppearance.Name, font: NSFont, background: NSColor, text: NSColor, caret: NSColor, selection: NSColor, tokens: [TokenKind: TokenStyle]) {
        self.name = name
        self.appearance = appearance
        self.font = font
        self.background = background
        self.text = text
        self.caret = caret
        self.selection = selection
        self.tokens = tokens
    }

    /// Attributes of unstyled text.
    var baseAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: text] }

    /// The default.
    public static let `default` = dark

    public static let dark = make(
        name: "Default Dark", appearance: .darkAqua, background: 0x1E1F22, text: 0xDCDFE4, selection: 0x2F4F7F,
        red: 0xFF8A80, blue: 0x8AB4F8, green: 0x81C995, purple: 0xD2A8FF, orange: 0xFFB86B, grey: 0x8B949E)

    public static let light = make(
        name: "Default Light", appearance: .aqua, background: 0xFFFFFF, text: 0x1F2328, selection: 0xB3D4FC,
        red: 0xB3261E, blue: 0x0B57D0, green: 0x1E6E3A, purple: 0x7B3FA0, orange: 0x9A4A00, grey: 0x6E7781)

    private static func make(name: String, appearance: NSAppearance.Name, background: Int, text: Int, selection: Int,
                             red: Int, blue: Int, green: Int, purple: Int, orange: Int, grey: Int) -> EditorTheme {
        let red = NSColor(hex: red), blue = NSColor(hex: blue), green = NSColor(hex: green)
        let purple = NSColor(hex: purple), orange = NSColor(hex: orange), grey = NSColor(hex: grey)
        return EditorTheme(
            name: name,
            appearance: appearance,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            background: NSColor(hex: background),
            text: NSColor(hex: text),
            caret: NSColor(hex: text),
            selection: NSColor(hex: selection),
            tokens: [
                .heading: TokenStyle(color: blue, bold: true),
                .headingMarker: TokenStyle(color: grey, bold: true),
                .emphasis: TokenStyle(italic: true),
                .strong: TokenStyle(bold: true),
                .strikethrough: TokenStyle(color: grey, strikethrough: true),
                .code: TokenStyle(color: orange),
                .codeBlock: TokenStyle(color: orange),
                .codeFence: TokenStyle(color: grey),
                .link: TokenStyle(color: blue),
                .linkURL: TokenStyle(color: grey, underline: true),
                .linkLabel: TokenStyle(color: purple),
                .image: TokenStyle(color: purple),
                .quote: TokenStyle(color: green),
                .quoteMarker: TokenStyle(color: green, bold: true),
                .listMarker: TokenStyle(color: red, bold: true),
                .taskMarker: TokenStyle(color: red, bold: true),
                .hr: TokenStyle(color: grey, bold: true),
                .html: TokenStyle(color: green),
                .frontMatter: TokenStyle(color: grey),
                .math: TokenStyle(color: purple),
                .escape: TokenStyle(color: grey),
                .delimiter: TokenStyle(color: grey),
                .tableHeader: TokenStyle(bold: true),
                .tableDelimiter: TokenStyle(color: grey),
            ]
        )
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
