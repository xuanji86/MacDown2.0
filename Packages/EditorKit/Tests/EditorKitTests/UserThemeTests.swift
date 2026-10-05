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
        #expect(store.all.map(\.name) == ThemeLibrary.all.map(\.name))  // nothing read before start()
        store.reload()
        #expect(store.all.map(\.name) == ThemeLibrary.all.map(\.name) + ["Mine"])
    }

    @Test func storeReloadsWhenFilesChange() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UserThemeStore(directory: folder)
        store.start()
        #expect(store.userThemes.isEmpty)

        try Self.write(Self.json(name: "One"), as: "one.json", in: folder)
        #expect(await eventually(timeout: .seconds(10)) { store.userThemes.map(\.name) == ["One"] }, "a new file is picked up")

        try Self.write(Self.json(name: "One", background: "#222222"), as: "one.json", in: folder)  // edited in place
        #expect(await eventually(timeout: .seconds(10)) { store.userThemes.first?.background == NSColor(hex: 0x222222) }, "an edit is picked up")

        try Self.write("{ broken", as: "two.json", in: folder)
        #expect(await eventually(timeout: .seconds(10)) { store.skipped.map(\.file) == ["two.json"] }, "a broken file is skipped, the rest stays")
        #expect(store.userThemes.map(\.name) == ["One"])

        try FileManager.default.removeItem(at: folder.appending(path: "one.json"))
        #expect(await eventually(timeout: .seconds(10)) { store.userThemes.isEmpty }, "a deleted file disappears")
    }

    @Test func storeNoticesAFolderCreatedAfterStart() async throws {
        let parent = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Themes", directoryHint: .isDirectory)
        let store = UserThemeStore(directory: folder)
        store.start()  // the folder does not exist yet
        #expect(store.userThemes.isEmpty)
        #expect(store.ensureDirectory())
        try Self.write(Self.json(name: "Late"), as: "late.json", in: folder)
        #expect(await eventually(timeout: .seconds(10)) { store.userThemes.map(\.name) == ["Late"] })
    }
}
