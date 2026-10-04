import Foundation
import Testing
@testable import WorkspaceKit

struct SplitModeTests {
    private func suite() -> UserDefaults {
        let name = "SplitModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: The invariant

    @Test func noModeHidesBothPanes() {
        for mode in SplitMode.allCases { #expect(mode.showsEditor || mode.showsPreview) }
    }

    @Test func cyclingVisitsEveryModeAndNeverLeavesTheValidOnes() {
        var seen: [SplitMode] = []
        var mode = SplitMode.both
        for _ in SplitMode.allCases {
            seen.append(mode)
            mode = mode.next
            #expect(mode.showsEditor || mode.showsPreview)
        }
        #expect(Set(seen) == Set(SplitMode.allCases))
        #expect(mode == .both)  // a full turn comes back
    }

    @Test func aCorruptedRecordResolvesToAValidMode() {
        for garbage in ["", "none", "hidden", "neither", "BOTH", " both", "previewonly"] {
            let mode = SplitMode.resolve(cli: nil, remembered: nil, restored: garbage, setting: .previewOnly)
            #expect(mode == .previewOnly)  // falls through to the Settings default
        }
        #expect(SplitMode.resolve(cli: nil, remembered: nil, restored: "none", setting: .both) == .both)
    }

    // MARK: Precedence

    @Test func precedenceIsCLIThenRememberedThenRestoredThenSetting() {
        func resolve(_ cli: SplitMode?, _ remembered: SplitMode?, _ restored: String?) -> SplitMode {
            SplitMode.resolve(cli: cli, remembered: remembered, restored: restored, setting: .both)
        }
        #expect(resolve(.previewOnly, .editorOnly, "editorOnly") == .previewOnly)
        #expect(resolve(nil, .editorOnly, "previewOnly") == .editorOnly)
        #expect(resolve(nil, nil, "previewOnly") == .previewOnly)
        #expect(resolve(nil, nil, nil) == .both)
    }

    // MARK: Settings default

    @Test func theSettingDefaultsToBothAndIgnoresUnknownValues() {
        let defaults = suite()
        #expect(SplitMode.setting(in: defaults) == .both)
        defaults.set("previewOnly", forKey: SplitMode.settingKey)
        #expect(SplitMode.setting(in: defaults) == .previewOnly)
        defaults.set("nonsense", forKey: SplitMode.settingKey)
        #expect(SplitMode.setting(in: defaults) == .both)
        defaults.set(3, forKey: SplitMode.settingKey)
        #expect(SplitMode.setting(in: defaults) == .both)
    }

    // MARK: Workspace memory

    @Test func theMemoryRoundTripsThroughDefaultsAndSkipsBadRows() {
        let defaults = suite()
        var memory = LayoutMemory()
        memory.remember(.previewOnly, forRoots: ["/a", "/b"])
        memory.save(to: defaults)
        #expect(LayoutMemory(defaults: defaults) == memory)
        defaults.set([["key": "/a", "mode": "previewOnly"], ["key": "/x", "mode": "hidden"], ["key": "", "mode": "both"], ["mode": "both"]], forKey: LayoutMemory.defaultsKey)
        #expect(LayoutMemory(defaults: defaults).entries == [.init(key: "/a", mode: .previewOnly)])
        defaults.set("garbage", forKey: LayoutMemory.defaultsKey)
        #expect(LayoutMemory(defaults: defaults).entries.isEmpty)
    }

    @Test func rememberingReplacesAndMovesToTheFront() {
        var memory = LayoutMemory()
        memory.remember(.editorOnly, forRoots: ["/a"])
        memory.remember(.previewOnly, forRoots: ["/b"])
        memory.remember(.both, forRoots: ["/a"])
        #expect(memory.entries == [.init(key: "/a", mode: .both), .init(key: "/b", mode: .previewOnly)])
        #expect(memory.mode(forRoots: ["/b"]) == .previewOnly)
        #expect(memory.mode(forRoots: ["/zzz", "/b", "/a"]) == .previewOnly)  // first known root wins
        #expect(memory.mode(forRoots: ["/zzz"]) == nil)
    }

    @Test func theMemoryIsCappedAndForgetsTheOldest() {
        var memory = LayoutMemory()
        for i in 0..<(LayoutMemory.capacity + 10) { memory.remember(.previewOnly, forRoots: ["/w\(i)"]) }
        #expect(memory.entries.count == LayoutMemory.capacity)
        #expect(memory.mode(forRoots: ["/w0"]) == nil)
        #expect(memory.mode(forRoots: ["/w\(LayoutMemory.capacity + 9)"]) == .previewOnly)
        // A stored list longer than the cap (an older version) is cut on load as well.
        let defaults = suite()
        defaults.set((0..<200).map { ["key": "/k\($0)", "mode": "both"] }, forKey: LayoutMemory.defaultsKey)
        #expect(LayoutMemory(defaults: defaults).entries.count == LayoutMemory.capacity)
    }
}

struct LayoutHintsTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "layout-hints-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aHintIsTakenOnceByTheFileItNames() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try LayoutHints.write(.previewOnly, for: ["/notes/a.md"], in: dir, now: t0)
        #expect(LayoutHints.take(for: ["/other.md"], in: dir, now: t0) == nil)
        #expect(LayoutHints.take(for: ["/other.md", "/notes/a.md"], in: dir, now: t0.addingTimeInterval(5)) == .previewOnly)
        #expect(LayoutHints.take(for: ["/notes/a.md"], in: dir, now: t0.addingTimeInterval(5)) == nil)  // used up
    }

    @Test func aStaleHintIsIgnoredAndRemoved() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try LayoutHints.write(.editorOnly, for: ["/a.md"], in: dir, now: t0)
        #expect(LayoutHints.take(for: ["/a.md"], in: dir, now: t0.addingTimeInterval(LayoutHints.lifetime + 1)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func theNewestOfSeveralHintsWins() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try LayoutHints.write(.editorOnly, for: ["/a.md"], in: dir, now: t0)
        try LayoutHints.write(.previewOnly, for: ["/a.md"], in: dir, now: t0.addingTimeInterval(10))
        #expect(LayoutHints.take(for: ["/a.md"], in: dir, now: t0.addingTimeInterval(11)) == .previewOnly)
    }

    @Test func writingDropsStaleHints() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try LayoutHints.write(.editorOnly, for: ["/a.md"], in: dir, now: t0)
        try LayoutHints.write(.previewOnly, for: ["/b.md"], in: dir, now: t0.addingTimeInterval(1000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func invalidFilesAreIgnoredAndRemoved() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let at = t0.timeIntervalSince1970
        try Data("not json".utf8).write(to: dir.appending(path: "a.json"))
        try Data(#"{"mode":"hidden","paths":["/a.md"],"at":\#(at)}"#.utf8).write(to: dir.appending(path: "b.json"))  // not a mode
        try Data(#"{"mode":"both","paths":"/a.md","at":\#(at)}"#.utf8).write(to: dir.appending(path: "c.json"))  // wrong shape
        try Data(repeating: 0x20, count: 2_000_000).write(to: dir.appending(path: "d.json"))  // oversized
        try Data("keep".utf8).write(to: dir.appending(path: "other.txt"))  // not ours
        #expect(LayoutHints.take(for: ["/a.md"], in: dir, now: t0) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["other.txt"])
    }

    @Test func aMissingFolderIsNoHint() {
        #expect(LayoutHints.take(for: ["/a.md"], in: URL(filePath: "/nonexistent-\(UUID().uuidString)"), now: t0) == nil)
    }

    @Test func theFolderIsScopedBySuiteAndCannotEscape() {
        let home = URL(filePath: "/Users/x")
        let base = "/Users/x/Library/Caches/io.github.xuanji86.MacDown2/layout-hints/"
        #expect(LayoutHints.directory(home: home, suite: nil).path == base + "app")
        #expect(LayoutHints.directory(home: home, suite: "macdown2-iso-1").path == base + "macdown2-iso-1")
        for bad in ["", "..", ".", "../x", "a/b"] { #expect(LayoutHints.directory(home: home, suite: bad).path == base + "app") }
    }
}
