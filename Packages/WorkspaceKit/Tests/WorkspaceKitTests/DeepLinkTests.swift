import Foundation
import Testing
@testable import WorkspaceKit

struct DeepLinkTests {
    /// A made-up file system: folders and files by path, so no test touches the real disk.
    private func fs(files: [String] = ["/notes/a.md", "/notes/b.QMD", "/notes/c.txt", "/notes/secret.pem", "/Apps/X.app"], folders: [String] = ["/notes", "/notes/sub"]) -> (URL) -> DeepLink.Kind? {
        { url in files.contains(url.path) ? .file : folders.contains(url.path) ? .folder : nil }
    }

    private func parse(_ text: String) -> Result<DeepLink, DeepLink.Failure> {
        DeepLink.parse(URL(string: text)!, kind: fs())
    }

    private func failure(_ text: String) -> DeepLink.Failure? {
        if case .failure(let f) = parse(text) { return f }
        return nil
    }

    @Test func openFile() throws {
        let link = try parse("macdown2://open?path=/notes/a.md").get()
        #expect(link.url.path == "/notes/a.md")
        #expect(link.kind == .file)
        #expect(link.line == nil)
        #expect(link.layout == nil)
    }

    @Test func percentEncodingIsDecodedAndTheSchemeAndHostAreCaseInsensitive() throws {
        let link = try parse("MacDown2://OPEN?path=%2Fnotes%2Fb.QMD&line=12&layout=preview-only").get()
        #expect(link.url.path == "/notes/b.QMD")
        #expect(link.line == 12)
        #expect(link.layout == .previewOnly)
    }

    @Test func spacesAndNonASCIIInThePath() throws {
        let kind: (URL) -> DeepLink.Kind? = { $0.path == "/My Notes/日本語 é.md" ? .file : nil }
        let link = try DeepLink.parse(URL(string: "macdown2://open?path=/My%20Notes/%E6%97%A5%E6%9C%AC%E8%AA%9E%20%C3%A9.md")!, kind: kind).get()
        #expect(link.url.path == "/My Notes/日本語 é.md")
    }

    @Test func aFolderIsAWorkspace() throws {
        #expect(try parse("macdown2://open?path=/notes").get().kind == .folder)
        #expect(try parse("macdown2://workspace?path=/notes/sub/&layout=both").get().kind == .folder)
        #expect(try parse("macdown2://workspace?path=/notes").get().layout == nil)
    }

    @Test func lineIsForFilesAndIgnoredForFolders() throws {
        #expect(try parse("macdown2://open?path=/notes&line=3").get().line == nil)
        #expect(try parse("macdown2://open?path=/notes/a.md&line=1").get().line == 1)
        #expect(try parse("macdown2://open?path=/notes/a.md&line=10000000").get().line == 10_000_000)
    }

    @Test(arguments: ["0", "-1", "+3", "1.5", "abc", "10000001", "99999999999999999999", "٣", "1 "])
    func aBadLineRefusesTheWholeLink(_ line: String) {
        #expect(failure("macdown2://open?path=/notes/a.md&line=\(line.replacingOccurrences(of: " ", with: "%20"))") == .badParameter("line"))
    }

    @Test(arguments: ["both", "editor-only", "preview-only"])
    func layouts(_ layout: String) throws {
        #expect(try parse("macdown2://open?path=/notes/a.md&layout=\(layout)").get().layout != nil)
    }

    @Test func anUnknownLayoutIsRefused() {
        #expect(failure("macdown2://open?path=/notes/a.md&layout=sideways") == .badParameter("layout"))
    }

    @Test(arguments: [
        "https://example.com/open?path=/notes/a.md",
        "file:///notes/a.md",
        "macdown2://run?path=/notes/a.md",
        "macdown2://open/extra?path=/notes/a.md",
        "macdown2://user@open?path=/notes/a.md",
        "macdown2://open:80?path=/notes/a.md",
        "macdown2:/open?path=/notes/a.md",
        "macdown2://?path=/notes/a.md",
    ])
    func onlyOpenAndWorkspaceLinksAreAccepted(_ text: String) {
        #expect(failure(text) == .unsupportedLink)
    }

    @Test func pathIsRequiredOnceAndNonEmpty() {
        #expect(failure("macdown2://open") == .badParameter("path"))
        #expect(failure("macdown2://open?path=") == .badParameter("path"))
        #expect(failure("macdown2://open?line=3") == .badParameter("path"))
        #expect(failure("macdown2://open?path=/notes/a.md&path=/notes/c.txt") == .badParameter("path"))
        #expect(failure("macdown2://open?path=/notes/a.md&line=1&line=2") == .badParameter("line"))
    }

    @Test(arguments: [
        "relative/a.md", "./a.md", "a.md", "~/a.md", "%7E/a.md",
        "file:///notes/a.md", "//notes/../etc/passwd",
        "/notes/../notes/a.md", "/notes/sub/../a.md", "/..", "/notes/..", "/notes/%2E%2E/a.md",
        "/notes/a.md%00.txt", "/notes/a.md%0A", "/notes/a%1B.md", "/notes/a.md%7F",
    ])
    func unsafePathsAreRefused(_ path: String) {
        #expect(failure("macdown2://open?path=\(path)") == .unsafePath)
    }

    @Test func aTooLongPathIsRefused() {
        let long = "/notes/" + String(repeating: "a", count: DeepLink.maxPathLength) + ".md"
        #expect(failure("macdown2://open?path=\(long)") == .unsafePath)
    }

    @Test func aDotComponentIsNotATraversal() throws {
        #expect(try parse("macdown2://open?path=/notes/./a.md").get().url.path == "/notes/a.md")
    }

    @Test func missingPathsAreNotFound() {
        #expect(failure("macdown2://open?path=/notes/missing.md") == .notFound)
        #expect(failure("macdown2://workspace?path=/nowhere") == .notFound)
    }

    @Test func onlyDocumentsAreOpenedAsFiles() {
        #expect(failure("macdown2://open?path=/notes/secret.pem") == .unsupportedFileType)
        #expect(failure("macdown2://open?path=/Apps/X.app") == .unsupportedFileType)
        #expect(DeepLink.parse(URL(string: "macdown2://open?path=/notes/c.txt")!, kind: fs()) == .success(DeepLink(url: URL(filePath: "/notes/c.txt"), kind: .file, line: nil, layout: nil)))
    }

    @Test func workspaceNeedsAFolder() {
        #expect(failure("macdown2://workspace?path=/notes/a.md") == .badParameter("path"))
    }

    @Test func theFileExtensionsAreTheTreesOwn() {
        #expect(DeepLink.fileExtensions == FileTreeOptions.openableExtensions)
        #expect(DeepLink.fileExtensions.isSuperset(of: ["md", "markdown", "qmd", "txt", "mdown", "text"]))
    }

    @Test func aSymlinkToAnotherTypeIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deeplink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appending(path: "id_rsa")
        try "x".write(to: secret, atomically: true, encoding: .utf8)
        let good = dir.appending(path: "ok.md")
        try "# ok".write(to: good, atomically: true, encoding: .utf8)
        let link = dir.appending(path: "innocent.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        func path(_ url: URL) -> String { url.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/-_."))) ?? "" }
        #expect(DeepLink.parse(URL(string: "macdown2://open?path=\(path(link))")!) == .failure(.unsupportedFileType))
        let real = DeepLink.parse(URL(string: "macdown2://open?path=\(path(good))&line=2")!)
        #expect((try? real.get().line) == 2)  // against the real file system, with the default lookup
        let folder = try DeepLink.parse(URL(string: "macdown2://open?path=\(path(dir))")!).get()
        #expect(folder.kind == .folder)
        #expect(folder.url.path == dir.standardizedFileURL.path)
        // A symlinked folder (`/tmp`, a synced `~/notes`) is a folder, not a file the extension check would refuse.
        let folderLink = dir.appending(path: "linked-folder")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: dir)
        let viaLink = try DeepLink.parse(URL(string: "macdown2://workspace?path=\(path(folderLink))")!).get()
        #expect(viaLink.kind == .folder)
        #expect(viaLink.url.path == folderLink.standardizedFileURL.path)  // named as the user wrote it
    }
}
