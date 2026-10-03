import Foundation
import Testing
@testable import WorkspaceKit

struct FileTreeModelTests {
    private func names(_ nodes: [FileNode]) -> [String] { nodes.map(\.name) }

    @Test func foldersComeFirstThenNaturalOrder() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("file10.md"); try t.file("file2.md"); try t.file("Apple.md"); try t.file("banana.md")
        try t.dir("zeta"); try t.dir("Alpha"); try t.dir("chapter 10"); try t.dir("chapter 9")
        let listed = try DirectoryLister.list(t.url, options: FileTreeOptions())
        #expect(names(listed) == ["Alpha", "chapter 9", "chapter 10", "zeta", "Apple.md", "banana.md", "file2.md", "file10.md"])
    }

    @Test func defaultFilterShowsMarkdownFamilyAndFolders() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for f in ["a.md", "b.MARKDOWN", "c.qmd", "d.txt", "e.png", "f.html", "g.swift", ".hidden.md", "noext"] { try t.file(f) }
        try t.dir("sub"); try t.dir(".dotfolder")
        let listed = try DirectoryLister.list(t.url, options: FileTreeOptions())
        #expect(names(listed) == ["sub", "a.md", "b.MARKDOWN", "c.qmd", "d.txt"])
    }

    @Test func showAllLiftsTheExtensionFilterButNotTheIgnoreRules() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for f in ["a.md", "e.png", ".env", "notes_files"] { try t.file(f) }  // `notes_files` is a plain file
        for d in ["node_modules", ".git", "page_files", "src"] { try t.dir(d) }
        let listed = try DirectoryLister.list(t.url, options: FileTreeOptions(showAllFiles: true))
        #expect(names(listed) == ["src", ".env", "a.md", "e.png", "notes_files"])
    }

    @Test func customRulesReplaceTheDefaults() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("build"); try t.dir("node_modules")
        let options = FileTreeOptions(ignore: IgnoreRules(names: ["build"], suffixes: []))
        #expect(names(try DirectoryLister.list(t.url, options: options)) == ["node_modules"])
    }

    @Test func symlinkedFolderBrowsesAsFolderAndPackagesAreFiles() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("real"); try t.dir("Thing.app")
        try FileManager.default.createSymbolicLink(at: t.url.appending(path: "link"), withDestinationURL: t.url.appending(path: "real"))
        let listed = try DirectoryLister.list(t.url, options: FileTreeOptions(showAllFiles: true))
        #expect(listed.first { $0.name == "link" }?.isDirectory == true)
        #expect(listed.first { $0.name == "Thing.app" }?.isDirectory == false)
    }

    @Test func subdirectoriesLoadLazily() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("sub/deep/a.md"); try t.file("top.md")
        var model = FileTreeModel(roots: [t.url])
        #expect(model.children(of: t.url) != nil)
        #expect(model.children(of: t.url.appending(path: "sub")) == nil)  // nothing below the root was read
        model.setExpanded(t.url.appending(path: "sub"), true)
        #expect(names(model.children(of: t.url.appending(path: "sub"))!) == ["deep"])
        #expect(model.children(of: t.url.appending(path: "sub/deep")) == nil)
    }

    @Test func rowsFlattenExpandedDirectoriesOnly() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/one.md"); try t.file("a/b/two.md"); try t.file("z.md")
        var model = FileTreeModel(roots: [t.url])
        #expect(model.rows().map(\.node.name) == [t.url.lastPathComponent, "a", "z.md"])
        model.setExpanded(t.url.appending(path: "a"), true)
        model.setExpanded(t.url.appending(path: "a/b"), true)
        let rows = model.rows()
        #expect(rows.map(\.node.name) == [t.url.lastPathComponent, "a", "b", "two.md", "one.md", "z.md"])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 2, 1])
        model.setExpanded(t.url.appending(path: "a"), false)
        #expect(model.rows().map(\.node.name) == [t.url.lastPathComponent, "a", "z.md"])
    }

    @Test func severalRootsAndNoDuplicates() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("one/a.md"); try t.file("two/b.md")
        var model = FileTreeModel(roots: [t.url.appending(path: "one"), t.url.appending(path: "two", directoryHint: .isDirectory)])
        #expect(model.roots.count == 2)
        let added = model.addRoot(t.url.appending(path: "two"))  // same folder, no trailing slash
        #expect(!added)
        #expect(model.rows().map(\.node.name) == ["one", "a.md", "two", "b.md"])
        model.removeRoot(t.url.appending(path: "one"))
        #expect(model.rows().map(\.node.name) == ["two", "b.md"])
    }

    @Test func reloadPicksUpNewFilesAndDropsVanishedFolders() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("sub/a.md")
        var model = FileTreeModel(roots: [t.url])
        let sub = t.url.appending(path: "sub")
        model.setExpanded(sub, true)
        try t.file("sub/b.md")
        #expect(names(model.children(of: sub)!) == ["a.md"])  // stale until told
        model.reload([sub])
        #expect(names(model.children(of: sub)!) == ["a.md", "b.md"])

        try FileManager.default.removeItem(at: sub)
        model.reload([t.url])  // the root's listing no longer has `sub`
        #expect(model.children(of: sub) == nil)
        #expect(!model.isExpanded(sub))
    }

    @Test func reloadIgnoresDirectoriesNeverLoaded() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.dir("sub")
        var model = FileTreeModel(roots: [t.url])
        model.reload([t.url.appending(path: "sub")])
        #expect(model.children(of: t.url.appending(path: "sub")) == nil)
    }

    @Test func switchingToShowAllRelistsLoadedDirectories() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md"); try t.file("pic.png")
        var model = FileTreeModel(roots: [t.url])
        #expect(names(model.children(of: t.url)!) == ["a.md"])
        model.setOptions(FileTreeOptions(showAllFiles: true))
        #expect(names(model.children(of: t.url)!) == ["a.md", "pic.png"])
    }

    @Test func unreadableFolderShowsEmptyAndIsFlagged() throws {
        try #require(getuid() != 0, "root can read anything")
        let t = try TempDir(); defer { t.cleanUp() }
        let locked = try t.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var model = FileTreeModel(roots: [t.url])
        model.setExpanded(locked, true)
        #expect(model.children(of: locked) == [])
        #expect(model.unreadable.contains(locked.fileKey))
    }
}
