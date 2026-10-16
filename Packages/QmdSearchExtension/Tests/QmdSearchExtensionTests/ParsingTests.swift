import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

// The fixtures are qmd 2.8.3's real output, recorded against a throwaway index (XDG_CACHE_HOME / QMD_CONFIG_DIR in a temp
// folder) for the folder /tmp/md2-qmd-fixture/ws, whose realpath is /private/tmp/md2-qmd-fixture/ws.

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureText(_ name: String) throws -> String { String(decoding: try fixture(name), as: UTF8.self) }

struct ParsingTests {
    @Test func version() throws {
        #expect(QmdParse.version(try fixtureText("version.txt")) == [2, 8, 3])
        #expect(QmdParse.version("qmd 10.0.1") == [10, 0, 1])
        #expect(QmdParse.version("qmd dev") == nil)
        #expect(QmdParse.isSupported([2, 8, 3]) && QmdParse.isSupported([2, 8, 0]) && QmdParse.isSupported([3, 0, 0]))
        #expect(!QmdParse.isSupported([2, 7, 9]) && !QmdParse.isSupported([1, 9, 9]))
    }

    @Test func collectionListIsTextAndNamesMayHoldSpaces() throws {
        #expect(QmdParse.collectionNames(fromList: try fixtureText("collection-list.txt")) == ["macdown2-ws-0badf00d", "my notes"])
        #expect(QmdParse.collectionNames(fromList: "No collections found. Run 'qmd collection add .' to create one.\n").isEmpty)
    }

    @Test func collectionShow() throws {
        let own = try #require(QmdParse.collection(named: "macdown2-ws-0badf00d", fromShow: try fixtureText("collection-show-own.txt")))
        #expect(own == QmdCollection(name: "macdown2-ws-0badf00d", path: "/private/tmp/md2-qmd-fixture/ws", pattern: "**/*.{md,markdown,qmd}", includedByDefault: false, hasUpdateCommand: false))
        let user = try #require(QmdParse.collection(named: "my notes", fromShow: try fixtureText("collection-show-user.txt")))
        #expect(user.path == "/private/tmp/md2-qmd-fixture/my notes" && user.includedByDefault && user.hasUpdateCommand)
        #expect(QmdParse.collection(named: "x", fromShow: "Collection not found: x") == nil)
    }

    @Test func searchJSONDecodesAndIgnoresUnknownFields() throws {
        let results = try QmdParse.results(try fixture("search.json"))
        #expect(results.count == 4)
        #expect(results[0].file == "qmd://macdown2-ws-0badf00d/doomed.md")  // deleted since indexing: qmd:// + docid
        #expect(results[1] == QmdParse.Result(
            file: "/private/tmp/md2-qmd-fixture/ws/alpha.md", line: 3, title: "Alpha Notes", score: 0,
            snippet: "@@ -2,4 @@ (1 before, 4 after)\n\nThis file talks about the quantum flux capacitor.\nIt has several lines.\n"))
        #expect(try QmdParse.results(try fixture("search-empty.json")).isEmpty)
        #expect(try QmdParse.results(Data(##"[{"file":"/a.md","line":2,"future":{"x":1},"docid":"#abc"}]"##.utf8)).map(\.line) == [2])
        #expect(throws: QmdError.badOutput) { try QmdParse.results(Data("Usage: qmd search [options] <query>".utf8)) }
    }

    @Test func theSnippetHeaderSaysWhereItStarts() {
        let snippet = "@@ -6,3 @@ (5 before, 0 after)\n\nThe flux capacitor appears here too.\n"
        #expect(QmdParse.snippetLine(snippet, line: 7) == "The flux capacitor appears here too.")
        #expect(QmdParse.snippetLine(snippet, line: 6) == "")
        #expect(QmdParse.snippetLine(snippet, line: 40) == nil)
        #expect(QmdParse.snippetLine("no header", line: 1) == nil)
    }

    @Test func resultsBecomeHitsInTheWorkspaceAsTheCallerSpellsIt() throws {
        let results = try QmdParse.results(try fixture("search.json"))
        let workspace = URL(filePath: "/tmp/md2-qmd-fixture/ws/", directoryHint: .isDirectory)
        let hits = results.compactMap { QmdMapping.hit($0, workspace: workspace, realRoot: "/private/tmp/md2-qmd-fixture/ws", query: "capacitor", source: "qmd") }
        #expect(hits.map(\.file.path) == ["/tmp/md2-qmd-fixture/ws/alpha.md", "/tmp/md2-qmd-fixture/ws/notes/gamma.markdown", "/tmp/md2-qmd-fixture/ws/notes/beta.qmd"])
        #expect(hits.map(\.line) == [3, 1, 7])
        #expect(hits[0].snippet == "This file talks about the quantum flux capacitor.")
        #expect(hits[0].highlights == [39..<48])
        #expect(hits.allSatisfy { $0.source == "qmd" && $0.columns == nil })

        let cjk = try QmdParse.results(try fixture("search-cjk.json")).compactMap {
            QmdMapping.hit($0, workspace: workspace, realRoot: "/private/tmp/md2-qmd-fixture/ws", query: "中文测试", source: "qmd")
        }
        #expect(cjk.map(\.line) == [8])
        #expect(cjk.first.map { ($0.snippet as NSString).substring(with: NSRange($0.highlights[0])) } == "中文测试")
    }

    @Test func hitsOutsideTheWorkspaceAreDropped() {
        // A user's collection on a parent folder also finds files next to the workspace.
        let workspace = URL(filePath: "/notes/book")
        func hit(_ file: String) -> SearchHit? {
            QmdMapping.hit(QmdParse.Result(file: file, line: 1, snippet: "@@ -1,1 @@ (0 before, 0 after)\nx\n"), workspace: workspace, realRoot: "/notes/book", query: "x", source: "qmd")
        }
        #expect(hit("/notes/book/a.md")?.file.path == "/notes/book/a.md")
        #expect(hit("/notes/other.md") == nil)
        #expect(hit("/notes/bookshelf/a.md") == nil)
        #expect(hit("./notes/book/b.md")?.file.path == "/notes/book/b.md")  // relative to the working directory, /
        #expect(hit("qmd://notes/book/a.md") == nil)
    }

    @Test func queryTermsAndLongLines() {
        #expect(QmdMapping.terms(of: #"flux "quantum capacitor" -qmd"#) == ["flux", "quantum capacitor"])
        let long = String(repeating: "word ", count: 60) + "needle" + String(repeating: " tail", count: 60)
        let (text, marks) = QmdMapping.shorten(long, terms: ["needle"])
        #expect((text as NSString).length <= QmdMapping.maxSnippet + 2)
        #expect(text.hasPrefix("…") && text.hasSuffix("…"))
        #expect(marks.count == 1 && (text as NSString).substring(with: NSRange(marks[0])) == "needle")
    }

    @Test func theErrorTextIsNodesErrorLine() throws {
        let stderr = try fixtureText("query-no-model-stderr.txt")
        #expect(QmdRunner.gist(of: stderr, status: 1) == #"Error: No model file found at "/nonexistent/gen.gguf""#)
        #expect(QmdRunner.gist(of: "Collection not found: nope\n", status: 1) == "Collection not found: nope")
        #expect(QmdRunner.gist(of: "", status: 3) == L10n.exitStatus(3))
    }
}

struct CollectionTests {
    private func collection(_ name: String, _ path: String) -> QmdCollection {
        QmdCollection(name: name, path: path, pattern: "**/*.md", includedByDefault: true, hasUpdateCommand: false)
    }

    @Test func anExistingCollectionOnTheFolderOrAParentIsReused() {
        let all = [collection("notes", "/u/notes"), collection("book", "/u/notes/book"), collection("macdown2-book-1", "/u/notes/book"), collection("other", "/u/notesy")]
        #expect(QmdMapping.covering(all, realRoot: "/u/notes/book")?.name == "macdown2-book-1")  // ours for exactly this folder first
        #expect(QmdMapping.covering(Array(all.prefix(2)), realRoot: "/u/notes/book/ch1")?.name == "book")  // the closest folder
        #expect(QmdMapping.covering(all, realRoot: "/u/notes")?.name == "notes")
        #expect(QmdMapping.covering(all, realRoot: "/u/note") == nil)
        #expect(QmdMapping.covering([collection("other", "/u/notesy")], realRoot: "/u/notes") == nil)  // a prefix of the name is not a parent
        #expect(QmdMapping.covering([collection("slash", "/u/notes/")], realRoot: "/u/notes/a")?.name == "slash")
    }

    @Test func collectionNamesAreStableSlugsWithAPathHash() {
        let a = QmdMapping.collectionName(forRealRoot: "/Users/me/My Book (2026)")
        #expect(a.hasPrefix("macdown2-my-book-2026-") && a.count == "macdown2-my-book-2026-".count + 8)
        #expect(a == QmdMapping.collectionName(forRealRoot: "/Users/me/My Book (2026)"))
        #expect(QmdMapping.collectionName(forRealRoot: "/a/notes") != QmdMapping.collectionName(forRealRoot: "/b/notes"))
        let cjk = QmdMapping.collectionName(forRealRoot: "/Users/me/笔记")
        #expect(cjk.hasPrefix("macdown2-") && cjk.count == "macdown2-".count + 8)
        let long = QmdMapping.collectionName(forRealRoot: "/x/" + String(repeating: "abc-", count: 30))
        #expect(long.count <= "macdown2-".count + 32 + 1 + 8 && !long.contains("--"))
    }
}
