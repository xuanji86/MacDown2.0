import AppKit
import Foundation
import Testing
@testable import EditorKit

struct ThemeJSONTests {
    static let sample = """
    {
      "name": "Sample", "appearance": "light", "counterpart": "Other",
      "font": { "name": "Menlo-Regular", "size": 15 },
      "colors": { "background": "#FFFFFF", "text": "#102030", "selection": "#11223344", "lineNumber": "#999999" },
      "tokens": {
        "heading": { "fg": "#0000FF", "bold": true },
        "link": { "fg": "#00FF00", "underline": true },
        "strikethrough": { "strikethrough": true, "italic": true },
        "somethingFromTheFuture": { "fg": "#FF0000" }
      }
    }
    """

    @Test func decodesTheDocumentedFormat() throws {
        let theme = try EditorTheme(json: Data(Self.sample.utf8))
        #expect(theme.name == "Sample")
        #expect(theme.appearance == .light)
        #expect(theme.counterpart == "Other")
        #expect(theme.font.fontName == "Menlo-Regular")
        #expect(theme.font.pointSize == 15)
        #expect(theme.background == NSColor(hex: 0xFFFFFF))
        #expect(theme.text == NSColor(hex: 0x102030))
        #expect(theme.selection == NSColor(hex: 0x112233, alpha: 0x44 / 255))
        #expect(theme.lineNumber == NSColor(hex: 0x999999))
        #expect(theme.tokens[.heading]?.color == NSColor(hex: 0x0000FF))
        #expect(theme.tokens[.heading]?.bold == true)
        #expect(theme.tokens[.heading]?.italic == false)
        #expect(theme.tokens[.link]?.underline == true)
        #expect(theme.tokens[.strikethrough]?.strikethrough == true)
        #expect(theme.tokens[.strikethrough]?.italic == true)
        #expect(theme.tokens[.strikethrough]?.color == nil)
        #expect(theme.tokens[.code] == nil)  // not mentioned: unstyled, not an error
        #expect(theme.tokens.count == 3)  // the unknown key is ignored
    }

    /// A valid minimal theme as a dictionary, so each test changes only what it is about.
    static func minimal(_ edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var dict: [String: Any] = ["name": "x", "appearance": "dark", "colors": ["background": "#000000", "text": "#FFFFFF"]]
        edit(&dict)
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func optionalPartsGetDerivedDefaults() throws {
        let theme = try EditorTheme(json: Self.minimal())
        #expect(theme.caret == theme.text)
        #expect(theme.selection == NSColor(hex: 0xFFFFFF, alpha: 0.25))
        #expect(theme.counterpart == nil)
        #expect(theme.tokens.isEmpty)
        #expect(theme.font.pointSize == 13)
        #expect(theme.font.isFixedPitch)
    }

    @Test func aFontThatIsNotInstalledFallsBackToSystemMonospaced() throws {
        let theme = try EditorTheme(json: Self.minimal { $0["font"] = ["name": "No Such Font 9000", "size": 11] })
        #expect(theme.font.pointSize == 11)
        #expect(theme.font.isFixedPitch)
    }

    @Test func malformedThemesAreRejected() {
        let bad: [Data] = [
            Self.minimal { $0["colors"] = ["background": "red", "text": "#FFFFFF"] },  // colour spelled wrong
            Self.minimal { $0["colors"] = ["background": "#FFF", "text": "#FFFFFF"] },  // 3-digit hex not supported
            Self.minimal { $0["appearance"] = "purple" },
            Self.minimal { $0["colors"] = ["text": "#FFFFFF"] },  // no background
            Self.minimal { $0["name"] = nil },
            Self.minimal { $0["tokens"] = ["heading": ["fg": "blue"]] },
            Data("not json".utf8),
        ]
        for (i, json) in bad.enumerated() {
            #expect(throws: (any Error).self, "case \(i)") { try EditorTheme(json: json) }
        }
    }

    @Test func appearanceSelectsTheChrome() throws {
        func chrome(_ a: String) throws -> NSAppearance.Name? {
            try EditorTheme(json: Self.minimal { $0["appearance"] = a }).chromeAppearance?.name
        }
        #expect(try chrome("light") == .aqua)
        #expect(try chrome("dark") == .darkAqua)
        #expect(try chrome("auto") == nil)  // follows the system
    }
}

struct BuiltInThemeTests {
    static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func everyShippedThemeFileIsLoadedExactlyOnce() throws {
        let dir = try #require(Bundle.module.url(forResource: "Themes", withExtension: nil, subdirectory: "Resources"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        #expect(Set(files) == Set(ThemeLibrary.builtInFiles))
        #expect(ThemeLibrary.all.count == ThemeLibrary.builtInFiles.count)
        #expect(Set(ThemeLibrary.all.map(\.name)).count == ThemeLibrary.all.count)
    }

    @Test func theRequestedSixAreThere() {
        let names = ThemeLibrary.all.map(\.name)
        for want in ["Default Dark", "Default Light", "Solarized Dark", "Solarized Light", "GitHub Light", "GitHub Dark"] {
            #expect(names.contains(want), "missing \(want)")
        }
    }

    @Test func defaultIsDark() {
        #expect(EditorTheme.default.name == "Default Dark")
        #expect(EditorTheme.default.appearance == .dark)
        #expect(EditorTheme.light.name == "Default Light")
    }

    @Test func counterpartsPairALightWithADarkTheme() throws {
        for theme in ThemeLibrary.all {
            let name = try #require(theme.counterpart, "\(theme.name) has no counterpart")
            let other = try #require(ThemeLibrary.theme(named: name), "\(theme.name): counterpart \(name) does not exist")
            #expect(other.counterpart == theme.name)
            #expect(other.appearance != theme.appearance)
        }
    }

    @Test func everyThemeStylesEveryTokenKind() {
        for theme in ThemeLibrary.all {
            for kind in TokenKind.allCases { #expect(theme.tokens[kind] != nil, "\(theme.name) has no style for \(kind)") }
        }
    }

    @Test func textAndTokensAreReadableOnTheBackground() {
        for theme in ThemeLibrary.all {
            #expect(Self.contrast(theme.text, theme.background) >= 4.5, "\(theme.name): body text")
            #expect(Self.contrast(theme.lineNumber, theme.background) >= 3, "\(theme.name): line numbers")
            for (kind, style) in theme.tokens {
                guard let color = style.color else { continue }
                let ratio = Self.contrast(color, theme.background)
                #expect(ratio >= 4.5, "\(theme.name): \(kind) is \(String(format: "%.2f", ratio)):1")
            }
            // Selected text keeps its colour, so the selection must not swallow it.
            let selection = theme.selection.usingColorSpace(.sRGB)!
            let selected = theme.background.usingColorSpace(.sRGB)!.blended(withFraction: selection.alphaComponent, of: selection.withAlphaComponent(1))!
            #expect(Self.contrast(theme.text, selected) >= 4.5, "\(theme.name): text on selection")
        }
    }
}

struct ThemeSelectionTests {
    func name(_ chosen: String, follow: Bool, dark: Bool) -> String {
        ThemeLibrary.resolve(name: chosen, followSystem: follow, systemIsDark: dark).name
    }

    @Test func aFixedChoiceIgnoresTheSystem() {
        #expect(name("Solarized Light", follow: false, dark: true) == "Solarized Light")
        #expect(name("Default Dark", follow: false, dark: false) == "Default Dark")
    }

    @Test func followingTheSystemPicksTheMatchingMemberOfThePair() {
        #expect(name("Solarized Dark", follow: true, dark: false) == "Solarized Light")
        #expect(name("Solarized Light", follow: true, dark: true) == "Solarized Dark")
        #expect(name("GitHub Light", follow: true, dark: false) == "GitHub Light")
        #expect(name("GitHub Dark", follow: true, dark: true) == "GitHub Dark")
    }

    @Test func anUnknownNameIsTheDefault() {
        #expect(name("Deleted Theme", follow: false, dark: false) == "Default Dark")
        #expect(name("Deleted Theme", follow: true, dark: false) == "Default Light")  // default's pair
    }

    @Test func themesWithoutAPartnerStayPut() throws {
        func make(_ name: String, _ appearance: String, counterpart: String? = nil) throws -> EditorTheme {
            try EditorTheme(json: ThemeJSONTests.minimal { $0["name"] = name; $0["appearance"] = appearance; if let counterpart { $0["counterpart"] = counterpart } })
        }
        let themes = [try make("Solo", "dark"), try make("Auto", "auto", counterpart: "Solo"), try make("Dangling", "dark", counterpart: "Gone")]
        for chosen in ["Solo", "Auto", "Dangling"] {
            #expect(ThemeLibrary.resolve(name: chosen, followSystem: true, systemIsDark: false, among: themes).name == chosen)
        }
    }
}
