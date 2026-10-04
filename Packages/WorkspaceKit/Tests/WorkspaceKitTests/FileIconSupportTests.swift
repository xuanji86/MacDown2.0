import Darwin
import Foundation
import Testing
@testable import WorkspaceKit

struct FileIconSupportTests {
    @Test func aStampLivesUntilItsFolderOrItselfChanges() {
        var stamps = FileIconStamps()
        let a = stamps.stamp(of: "/w/docs/a.md"), other = stamps.stamp(of: "/w/other/b.md")
        stamps.invalidate(directories: ["/w/docs"])
        #expect(stamps.stamp(of: "/w/docs/a.md") != a)  // a child of the changed folder
        #expect(stamps.stamp(of: "/w/other/b.md") == other)  // somewhere else: untouched
        let folder = stamps.stamp(of: "/w/docs")
        stamps.invalidate(directories: ["/w/docs"])
        #expect(stamps.stamp(of: "/w/docs") != folder)  // the folder's own icon (a custom icon is written inside it)
        let child = stamps.stamp(of: "/w/other/b.md")
        stamps.invalidateAll()
        #expect(stamps.stamp(of: "/w/other/b.md") != child && stamps.stamp(of: "/w/docs/a.md") != a)
    }

    @Test func aFetchFromBeforeInvalidateAllMayNotStore() {
        var stamps = FileIconStamps()
        let before = stamps.stamp(of: "/w/a.md")
        #expect(stamps.isCurrent(before))
        stamps.invalidate(directories: ["/w"])
        #expect(stamps.isCurrent(before))  // a folder change only makes the path stale; its result is still stored, then asked again
        stamps.invalidateAll()
        #expect(!stamps.isCurrent(before))  // the default app may have changed: this result must not repopulate the cache
        #expect(before.generation != stamps.stamp(of: "/w/a.md").generation && stamps.stamp(of: "/w/a.md").generation == stamps.generation)
        #expect(stamps.isCurrent(stamps.stamp(of: "/w/a.md")))
    }

    @Test func theParentOfARootChildIsTheRoot() {
        #expect(FileIconStamps.parent(of: "/a.md") == "/")
        #expect(FileIconStamps.parent(of: "/w/a.md") == "/w")
        #expect(FileIconStamps.parent(of: "/") == "/")
    }

    @Test func customIconFlagIsReadFromFinderInfo() throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let plain = try dir.file("plain.md"), custom = try dir.file("custom.md"), folder = try dir.dir("folder")
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04  // kHasCustomIcon (0x0400): a big-endian UInt16 at offset 8
        for url in [custom, folder] { #expect(setxattr(url.path, "com.apple.FinderInfo", info, info.count, 0, 0) == 0) }
        #expect(FinderInfo.hasCustomIcon(atPath: custom.path))
        #expect(FinderInfo.hasCustomIcon(atPath: folder.path))
        #expect(!FinderInfo.hasCustomIcon(atPath: plain.path))
        #expect(!FinderInfo.hasCustomIcon(atPath: dir.url.appending(path: "missing").path))
    }
}
