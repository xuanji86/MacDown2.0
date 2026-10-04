import Foundation
import Testing
@testable import MarkdownCore

@Test func includeTargetsResolveRelativeToTheIncludingFileAndNeverLeaveTheFolder() {
    #expect(QuartoIncludes.resolve("a.qmd", from: "") == "a.qmd")
    #expect(QuartoIncludes.resolve("./a.qmd", from: "") == "a.qmd")
    #expect(QuartoIncludes.resolve("c.qmd", from: "sub") == "sub/c.qmd")
    #expect(QuartoIncludes.resolve("../a.qmd", from: "sub") == "a.qmd")
    #expect(QuartoIncludes.resolve("sub/../a.qmd", from: "") == "a.qmd")
    for escape in ["../x.qmd", "sub/../../x.qmd", "/etc/passwd", "file:///etc/passwd", "https://example.com/a.qmd", "..", ".", "", "a\\b", "a\0b"] {
        #expect(QuartoIncludes.resolve(escape, from: "") == nil, "\(escape)")
    }
    #expect(QuartoIncludes.resolve("../../x.qmd", from: "sub") == nil)
}

@Test func includeLinesAreFoundOnlyOnALineOfTheirOwn() {
    let text = """
    # T
    {{< include a.qmd >}}
       {{<include  "b c.qmd"  >}}
    {{< include 'd.qmd' >}}
    text {{< include no.qmd >}}
        {{< include indented-code.qmd >}}
    {{< var x >}}
    """
    #expect(QuartoIncludes.targets(in: text) == ["a.qmd", "b c.qmd", "d.qmd"])
    #expect(QuartoIncludes.targets(in: "no shortcodes at all").isEmpty)
}

private func reader(_ files: [String: String], asked: ((String) -> Void)? = nil) -> (String) -> String? {
    { path in
        asked?(path)
        return files[path]
    }
}

@Test func filesAreCollectedTransitivelyRelativeToEachFile() {
    let files = [
        "a.qmd": "{{< include sub/b.qmd >}}",
        "sub/b.qmd": "{{< include c.qmd >}}\n\n{{< include ../d.qmd >}}",
        "sub/c.qmd": "C",
        "d.qmd": "D",
        "unused.qmd": "never asked for",
    ]
    let found = QuartoIncludes.files(for: "text\n\n{{< include a.qmd >}}\n", readFile: reader(files))
    #expect(found == ["a.qmd": files["a.qmd"]!, "sub/b.qmd": files["sub/b.qmd"]!, "sub/c.qmd": "C", "d.qmd": "D"])
}

@Test func collectingStopsAtCyclesAndAtTheDepthLimit() {
    var files = ["loop1.qmd": "{{< include loop2.qmd >}}", "loop2.qmd": "{{< include loop1.qmd >}}", "self.qmd": "{{< include self.qmd >}}"]
    var asked: [String] = []
    let cyc = QuartoIncludes.files(for: "{{< include loop1.qmd >}}\n\n{{< include self.qmd >}}", readFile: reader(files) { asked.append($0) })
    #expect(Set(cyc.keys) == ["loop1.qmd", "loop2.qmd", "self.qmd"])
    #expect(asked.sorted() == ["loop1.qmd", "loop2.qmd", "self.qmd"])  // each path is asked once

    files = (1...8).reduce(into: [:]) { $0["l\($1).qmd"] = "{{< include l\($1 + 1).qmd >}}" }
    files["l9.qmd"] = "end"
    let deep = QuartoIncludes.files(for: "{{< include l1.qmd >}}", readFile: reader(files))
    #expect(Set(deep.keys) == ["l1.qmd", "l2.qmd", "l3.qmd", "l4.qmd", "l5.qmd"])  // five levels, like the renderer
    #expect(QuartoIncludes.maxDepth == 5)
}

@Test func collectingIsBoundedAndSkipsWhatCannotBeRead() {
    let text = (0..<200).map { "{{< include f\($0).qmd >}}" }.joined(separator: "\n\n")
    let all = Dictionary(uniqueKeysWithValues: (0..<200).map { ("f\($0).qmd", "x") })
    #expect(QuartoIncludes.files(for: text, readFile: reader(all)).count == QuartoIncludes.maxFiles)
    #expect(QuartoIncludes.files(for: "{{< include ../out.qmd >}}\n\n{{< include missing.qmd >}}", readFile: reader(["../out.qmd": "leak", "out.qmd": "leak"])).isEmpty)
}

@Test func includesInsideBlockquotesAndListsAreFoundLikeTheRendererFindsThem() {
    let text = """
    > {{< include quote.qmd >}}
    >{{< include tight.qmd >}}
    > > {{< include nested.qmd >}}
    - {{< include bullet.qmd >}}
    1. {{< include numbered.qmd >}}
    - > {{< include both.qmd >}}
      {{< include continued.qmd >}}
    >     {{< include code-in-quote.qmd >}}
    -     {{< include code-in-list.qmd >}}
    > text {{< include text.qmd >}}
    -{{< include nospace.qmd >}}
    """
    #expect(QuartoIncludes.targets(in: text) == ["quote.qmd", "tight.qmd", "nested.qmd", "bullet.qmd", "numbered.qmd", "both.qmd", "continued.qmd"])
}

@Test func anIncludeInsideAQuoteIsCollectedTransitively() {
    let found = QuartoIncludes.files(for: "> {{< include child.qmd >}}\n", readFile: { $0 == "child.qmd" ? "> {{< include sub/grand.qmd >}}" : $0 == "sub/grand.qmd" ? "G" : nil })
    #expect(found == ["child.qmd": "> {{< include sub/grand.qmd >}}", "sub/grand.qmd": "G"])
}

@Test func theFileReaderStaysInsideTheFolderAndReadsOnlyUTF8() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "QuartoIncludesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("child".utf8).write(to: dir.appending(path: "sub/child.qmd"))
    try Data([0xFF, 0xFE, 0x00]).write(to: dir.appending(path: "bad.qmd"))
    let outside = dir.deletingLastPathComponent().appending(path: "QuartoIncludesTests-outside-\(UUID().uuidString).qmd")
    try Data("secret".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }

    let read = QuartoIncludes.fileReader(directory: dir)
    #expect(read("sub/child.qmd") == "child")
    #expect(read("bad.qmd") == nil && read("missing.qmd") == nil && read("sub") == nil)
    #expect(read("../" + outside.lastPathComponent) == nil)
    #expect(QuartoIncludes.fileReader(directory: nil)("sub/child.qmd") == nil)
}

@Test func theIncludeCacheReadsAgainOnlyWhatChangedAndReportsOutsideChanges() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "IncludeFileCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let child = dir.appending(path: "child.qmd")
    let date = Date(timeIntervalSince1970: 1_700_000_000)  // whole seconds: survives being set again exactly
    try Data("one".utf8).write(to: child)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: child.path)
    let cache = IncludeFileCache(directory: dir)
    func render() -> [String: String] {
        defer { cache.endRender() }
        return QuartoIncludes.files(for: "{{< include child.qmd >}}\n\n{{< include later.qmd >}}", readFile: cache.read)
    }
    #expect(render() == ["child.qmd": "one"])
    #expect(!cache.changed())

    // Same size and date: served from memory even though the bytes on disk are different now.
    try Data("two".utf8).write(to: child)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: child.path)
    #expect(render() == ["child.qmd": "one"] && !cache.changed())

    // A new date: seen by `changed` without a render, and read afresh by the next one.
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: child.path)
    #expect(cache.changed())
    #expect(render() == ["child.qmd": "two"] && !cache.changed())

    // A file that was missing appears; one that goes away is noticed too.
    try Data("later".utf8).write(to: dir.appending(path: "later.qmd"))
    #expect(cache.changed())
    #expect(render() == ["child.qmd": "two", "later.qmd": "later"] && !cache.changed())
    try FileManager.default.removeItem(at: child)
    #expect(cache.changed())
    #expect(render() == ["later.qmd": "later"] && !cache.changed())

    // An include the text no longer has stops being watched.
    _ = QuartoIncludes.files(for: "no includes", readFile: cache.read)
    cache.endRender()
    try Data("changed".utf8).write(to: dir.appending(path: "later.qmd"))
    #expect(!cache.changed())
    #expect(IncludeFileCache(directory: nil).read("child.qmd") == nil)
}
