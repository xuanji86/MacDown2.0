import AppKit
import Foundation
import Testing
@testable import EditorKit

/// Parsing, listing and name collisions of the user theme folder, and the hot reload of `UserThemeStore`.
@MainActor
struct UserThemeTests {
    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "md2-themes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func json(name: String, background: String = "#101010", text: String = "#EEEEEE", appearance: String = "dark", extra: String = "") -> String {
        """
        {"name": "\(name)", "appearance": "\(appearance)", "colors": {"background": "\(background)", "text": "\(text)"}\(extra)}
        """
    }

    static func write(_ text: String, as file: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appending(path: file))
    }

    @Test func missingFolderIsAnEmptyListing() {
        let listing = UserThemes.load(from: URL(filePath: "/nonexistent-\(UUID().uuidString)"))
        #expect(listing.themes.isEmpty && listing.skipped.isEmpty)
    }

    @Test func loadsValidThemesInFileNameOrder() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write(Self.json(name: "Zebra"), as: "b.json", in: folder)
        try Self.write(Self.json(name: "Apple", background: "#FFFFFF", text: "#000000", appearance: "light"), as: "A.JSON", in: folder)
        try Self.write("not a theme", as: "notes.txt", in: folder)  // wrong extension: ignored, not "skipped"
        try Self.write(Self.json(name: "Hidden"), as: ".hidden.json", in: folder)
        let listing = UserThemes.load(from: folder)
        #expect(listing.themes.map(\.name) == ["Apple", "Zebra"])  // a.json before b.json whatever the case
        #expect(listing.themes[0].appearance == .light)
        #expect(listing.skipped.isEmpty)
    }

    @Test func invalidFilesAreSkippedWithAReasonAndTheRestStillLoad() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write("{ not json", as: "1-broken.json", in: folder)
        try Self.write(Self.json(name: "Bad Colour", background: "red"), as: "2-colour.json", in: folder)
        try Self.write(#"{"name": "No colours", "appearance": "dark"}"#, as: "3-missing.json", in: folder)
        try Self.write(Self.json(name: "   "), as: "4-blank.json", in: folder)
        try Self.write(Self.json(name: "Good"), as: "5-good.json", in: folder)
        try Data(count: UserThemes.maxFileBytes + 1).write(to: folder.appending(path: "6-huge.json"))
        try FileManager.default.createDirectory(at: folder.appending(path: "7-dir.json"), withIntermediateDirectories: false)
        let listing = UserThemes.load(from: folder)
        #expect(listing.themes.map(\.name) == ["Good"])
        #expect(listing.skipped.map(\.file) == ["1-broken.json", "2-colour.json", "3-missing.json", "4-blank.json", "6-huge.json", "7-dir.json"])
        #expect(listing.skipped.allSatisfy { !$0.reason.isEmpty })
        #expect(listing.skipped.first { $0.file == "2-colour.json" }?.reason.contains("red") == true)
    }

    @Test func aNameTakenByABuiltInGetsTheUserSuffix() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write(Self.json(name: "Solarized Dark", background: "#000000"), as: "a.json", in: folder)
        let listing = UserThemes.load(from: folder)
        #expect(listing.themes.map(\.name) == ["Solarized Dark (User)"])
        // The built-in keeps its name and its colours.
        #expect(ThemeLibrary.theme(named: "Solarized Dark")?.background != listing.themes[0].background)
    }

    @Test func collisionsBetweenUserThemesAreNumberedInFileOrder() {
        func theme(_ name: String) -> EditorTheme { var t = EditorTheme.dark; t.name = name; return t }
        let names = UserThemes.resolveNames(
            [theme("Dark"), theme("Dark"), theme("Dark"), theme("Dark (User)"), theme("Mine"), theme("Mine")], builtIn: ["Dark"]
        ).map(\.name)
        #expect(names == ["Dark (User)", "Dark (User 2)", "Dark (User 3)", "Dark (User) (User)", "Mine", "Mine (User)"])
        // The same input gives the same output (nothing depends on a set's iteration order).
        #expect(UserThemes.resolveNames([theme("Dark"), theme("Dark")], builtIn: ["Dark"]).map(\.name) == ["Dark (User)", "Dark (User 2)"])
    }

    @Test func tokenColoursAndCounterpartSurviveTheRoundTrip() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extra = ##", "counterpart": "Default Light", "tokens": {"heading": {"fg": "#FF0000", "bold": true}, "future-kind": {"fg": "#00FF00"}}"##
        try Self.write(Self.json(name: "Mine", extra: extra), as: "mine.json", in: folder)
        let theme = try #require(UserThemes.load(from: folder).themes.first)
        #expect(theme.counterpart == "Default Light")
        #expect(theme.tokens[.heading]?.bold == true)
        #expect(theme.tokens[.heading]?.color == NSColor(hex: 0xFF0000))
        // A user theme takes part in "follow the system" like a built-in one: its counterpart is a built-in.
        let all = ThemeLibrary.all + [theme]
        #expect(ThemeLibrary.resolve(name: "Mine", followSystem: true, systemIsDark: false, among: all).name == "Default Light")
        #expect(ThemeLibrary.resolve(name: "Mine", followSystem: true, systemIsDark: true, among: all).name == "Mine")
        // A saved choice whose file was deleted falls back to the default.
        #expect(ThemeLibrary.resolve(name: "Gone", followSystem: false, systemIsDark: true, among: ThemeLibrary.all).name == EditorTheme.default.name)
    }

    // MARK: Store

    @Test func storeListsBuiltInsFirstThenUserThemes() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write(Self.json(name: "Mine"), as: "mine.json", in: folder)
        let store = UserThemeStore(directory: folder)
        #expect(store.all.map(\.name) == ThemeLibrary.all.map(\.name))  // nothing read before the first reload()
        store.rescan()
        #expect(store.all.map(\.name) == ThemeLibrary.all.map(\.name) + ["Mine"])
    }

    @Test func reloadOnlyPublishesWhenSomethingChanged() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UserThemeStore(directory: folder)
        store.rescan()
        #expect(store.revision == 0, "an empty folder is what the store starts with")

        try Self.write(Self.json(name: "One"), as: "one.json", in: folder)
        store.rescan()
        #expect(store.userThemes.map(\.name) == ["One"] && store.revision == 1)

        store.rescan()  // nothing changed
        try Self.write("junk", as: ".DS_Store", in: folder)  // unrelated file
        try Self.write("notes", as: "readme.txt", in: folder)
        store.rescan()
        #expect(store.revision == 1, "unrelated files and repeated reloads do not make every editor re-apply its theme")

        try Self.write(Self.json(name: "One", background: "#222222"), as: "one.json", in: folder)  // edited in place, same name
        store.rescan()
        #expect(store.revision == 2 && store.userThemes.first?.background == NSColor(hex: 0x222222))

        try Self.write("{ broken", as: "two.json", in: folder)
        store.rescan()
        #expect(store.revision == 3 && store.skipped.map(\.file) == ["two.json"] && store.userThemes.map(\.name) == ["One"])

        try FileManager.default.removeItem(at: folder.appending(path: "one.json"))
        store.rescan()
        #expect(store.userThemes.isEmpty && store.revision == 4)
    }

    @Test func skippedReasonsAreShortAndNameTheField() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write("{ broken", as: "1.json", in: folder)
        try Self.write(Self.json(name: "X", background: "red"), as: "2.json", in: folder)
        try Self.write(#"{"name": "X", "appearance": "dark"}"#, as: "3.json", in: folder)
        let reasons = UserThemes.load(from: folder).skipped.map(\.reason)
        #expect(reasons[0] == "not valid JSON")
        #expect(reasons[1].hasPrefix("colors.background: colour must be #RRGGBB"))
        #expect(reasons[2] == "missing \"colors\"")
    }

    @Test func aSymlinkedThemeFileIsLoaded() throws {
        let folder = try Self.makeFolder(), elsewhere = try Self.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try Self.write(Self.json(name: "Linked"), as: "real.json", in: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked.json"), withDestinationURL: elsewhere.appending(path: "real.json"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "dangling.json"), withDestinationURL: elsewhere.appending(path: "nothing.json"))
        let listing = UserThemes.load(from: folder)
        #expect(listing.themes.map(\.name) == ["Linked"])
        #expect(listing.skipped.map(\.file) == ["dangling.json"])
    }

    @Test func counterpartFollowsARenamedSibling() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A pair written together, both named like built-ins: both are renamed, and the pair must still point at each other.
        try Self.write(Self.json(name: "Solarized Dark", extra: #", "counterpart": "Solarized Light""#), as: "a.json", in: folder)
        try Self.write(Self.json(name: "Solarized Light", appearance: "light", extra: #", "counterpart": "Solarized Dark""#), as: "b.json", in: folder)
        // A custom dark theme whose partner is the built-in light one: unchanged.
        try Self.write(Self.json(name: "Night", extra: #", "counterpart": "GitHub Light""#), as: "c.json", in: folder)
        // A pair whose partner kept its name: unchanged.
        try Self.write(Self.json(name: "Dusk", extra: #", "counterpart": "Dawn""#), as: "d.json", in: folder)
        try Self.write(Self.json(name: "Dawn", appearance: "light"), as: "e.json", in: folder)
        let themes = UserThemes.load(from: folder).themes
        let byName = Dictionary(uniqueKeysWithValues: themes.map { ($0.name, $0) })
        #expect(byName["Solarized Dark (User)"]?.counterpart == "Solarized Light (User)")
        #expect(byName["Solarized Light (User)"]?.counterpart == "Solarized Dark (User)")
        #expect(byName["Night"]?.counterpart == "GitHub Light")
        #expect(byName["Dusk"]?.counterpart == "Dawn")
        let all = ThemeLibrary.all + themes
        #expect(ThemeLibrary.resolve(name: "Solarized Dark (User)", followSystem: true, systemIsDark: false, among: all).name == "Solarized Light (User)")
    }
}
