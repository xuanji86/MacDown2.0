import Foundation
import Testing
@testable import QuartoExtension

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
