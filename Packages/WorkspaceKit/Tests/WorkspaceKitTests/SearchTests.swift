import Foundation
import Testing
@testable import WorkspaceKit

// MARK: Query parsing and matching

struct SearchMatcherTests {
    private func matcher(_ text: String, regex: Bool = false) throws -> SearchMatcher {
        try SearchMatcher(SearchQuery(text: text, isRegex: regex))
    }

    private func match(_ line: String, _ query: String, regex: Bool = false) throws -> LineMatch? {
        try matcher(query, regex: regex).match(line)
    }

    @Test func parsesWordsPhrasesAndExclusions() {
        let parsed = TermParser.parse(#"alpha "exact phrase" -beta -"not this" -"#)
        #expect(parsed.include == ["alpha", "exact phrase", "-"])  // a lone "-" is a word
        #expect(parsed.exclude == ["beta", "not this"])
    }

    @Test func anUnclosedQuoteTakesTheRestAndCurlyQuotesWork() {
        #expect(TermParser.parse(#"a "half typed"#).include == ["a", "half typed"])
        #expect(TermParser.parse("“smart quoted” x").include == ["smart quoted", "x"])
        #expect(TermParser.parse(#"a "" b"#).include == ["a", "b"])
        #expect(TermParser.parse("词一\u{3000}词二").include == ["词一", "词二"])  // ideographic space separates words
    }

    @Test func blankQueries() {
        #expect(SearchQuery(text: "   ").isBlank)
        #expect(SearchQuery(text: "-only -excludes").isBlank)
        #expect(!SearchQuery(text: "x").isBlank)
        #expect(SearchQuery(text: " ", isRegex: true).isBlank)
    }

    @Test func caseAndDiacriticsAreIgnored() throws {
        #expect(try match("Un CAFÉ au lait", "cafe") != nil)
        #expect(try match("naive", "NAÏVE") != nil)
        #expect(try match("Ｈｅｌｌｏ", "hello") != nil)  // full-width forms
        #expect(try match("nothing here", "cafe") == nil)
    }

    @Test func cjkMatchesWithoutWordBoundaries() throws {
        let m = try match("本地全文搜索功能", "文搜索")
        #expect(m?.ranges == [3..<6])
        #expect(try match("本地全文搜索功能", "全文 功能") != nil)  // two words, same line
        #expect(try match("本地全文搜索功能", "全文 -搜索") == nil)
        #expect(try match("ひらがなとカタカナ", "カタカナ") != nil)
        #expect(try match("한국어 검색", "검색") != nil)
    }

    @Test func allWordsMustBeOnTheLineAndExclusionsRule() throws {
        #expect(try match("alpha beta gamma", "gamma alpha") != nil)
        #expect(try match("alpha gamma", "gamma beta") == nil)
        #expect(try match("alpha beta", "alpha -beta") == nil)
        #expect(try match("alpha", "alpha -beta") != nil)
        #expect(try match("alpha", "-beta") == nil)  // nothing positive to look for
    }

    @Test func phrasesMatchExactly() throws {
        #expect(try match("the quick brown fox", #""quick brown""#) != nil)
        #expect(try match("the quick  brown fox", #""quick brown""#) == nil)
        #expect(try match("quick red brown", #""quick brown""#) == nil)
        #expect(try match("the quick brown fox", #"fox -"quick brown""#) == nil)
    }

    @Test func rangesAreUTF16OffsetsAndMergeWhenTheyTouch() throws {
        let m = try match("😀 foo foofoo", "foo")
        #expect(m?.ranges == [3..<6, 7..<13])  // the emoji is two UTF-16 units
        let overlap = try match("abcd", "abc bcd")
        #expect(overlap?.ranges == [0..<4])
    }

    @Test func everyRequiredTermIsCheckedEvenWhenTheHighlightCapIsReached() throws {
        let line = String(repeating: "a ", count: 80) + "b"
        #expect(try match(line, "a b") != nil)
        #expect(try match(line, "b a") != nil)
        #expect(try match(String(repeating: "a ", count: 80), "a b") == nil)
        #expect(try match(line, "a b -c") != nil)
    }

    @Test func zeroLengthRegexMatchesDoNotUseUpTheCap() throws {
        let line = String(repeating: "a", count: 60) + "x"
        #expect(try match(line, "x*", regex: true)?.ranges == [60..<61])
    }

    @Test func regexMode() throws {
        let m = try match("v1.2 and v10.20", #"v\d+\.\d+"#, regex: true)
        #expect(m?.ranges == [0..<4, 9..<15])
        #expect(try match("ABC", "abc", regex: true) != nil)
        #expect(try match("abc", "x*", regex: true) == nil)  // matches only the empty string: not a hit
        #expect(try match("-x", "-x", regex: true) != nil)  // no -exclusion syntax in regex mode
    }

    @Test func anInvalidRegexIsAClearErrorNotACrash() {
        #expect(throws: SearchError.invalidRegex) { try SearchMatcher(SearchQuery(text: "(unclosed", isRegex: true)) }
        #expect(throws: SearchError.invalidRegex) { try SearchMatcher(SearchQuery(text: "[a-", isRegex: true)) }
        #expect(SearchError.invalidRegex.errorDescription == "正则表达式无效")
    }

    @Test func fileQuickRejectUsesEveryRequiredTerm() throws {
        let m = try matcher("alpha beta")
        #expect(m.fileMayMatch("beta\nALPHA" as NSString))
        #expect(!m.fileMayMatch("alpha only" as NSString))
        #expect(try matcher("x+", regex: true).fileMayMatch("anything" as NSString))  // regex: no shortcut
    }
}

struct SearchSnippetTests {
    @Test func shortLinesLoseTheirIndentation() {
        let s = SearchSnippet.make(line: "    - item with foo", ranges: [16..<19])
        #expect(s.text == "- item with foo")
        #expect(s.highlights == [12..<15])
        #expect((s.text as NSString).substring(with: NSRange(s.highlights[0])) == "foo")
    }

    @Test func longLinesAreCutAroundTheFirstMatch() {
        let line = String(repeating: "x", count: 300) + "NEEDLE" + String(repeating: "y", count: 300)
        let s = SearchSnippet.make(line: line, ranges: [300..<306])
        #expect(s.text.hasPrefix("…") && s.text.hasSuffix("…"))
        #expect((s.text as NSString).length <= SearchSnippet.maxUnits + 2)
        #expect((s.text as NSString).substring(with: NSRange(s.highlights[0])) == "NEEDLE")
    }

    @Test func aCutNeverSplitsASurrogatePairOrCluster() {
        let line = String(repeating: "👨‍👩‍👧", count: 80) + "中文" + String(repeating: "😀", count: 80)
        let start = (String(repeating: "👨‍👩‍👧", count: 80) as NSString).length
        let s = SearchSnippet.make(line: line, ranges: [start..<start + 2])
        #expect(!s.text.unicodeScalars.contains("\u{FFFD}"))
        #expect((s.text as NSString).substring(with: NSRange(s.highlights[0])) == "中文")
        // every character of the text is a whole one: round-tripping through UTF-8 loses nothing
        #expect(String(decoding: Array(s.text.utf8), as: UTF8.self) == s.text)
    }

    @Test func aMatchInTheTrailingWhitespaceOfALongLineDoesNotCrash() {
        let line = String(repeating: "x", count: 150) + String(repeating: " ", count: 200)
        let s = SearchSnippet.make(line: line, ranges: [348..<350])  // what the regex ` {2}$` finds
        #expect(s.highlights.count == 1)
        #expect((s.text as NSString).substring(with: NSRange(s.highlights[0])) == "  ")
        let end = SearchSnippet.make(line: "ab   ", ranges: [3..<5])
        #expect(end.text == "ab   " && end.highlights == [3..<5])
    }

    @Test func randomLinesAndRangesNeverTrapAndKeepHighlightsInsideTheText() {
        var rng = SplitMix(seed: 42)
        let alphabet = ["x", " ", "\t", "\u{3000}", "中", "😀", "é", "e\u{301}", "a"]
        for _ in 0..<3000 {
            let line = (0..<Int(rng.next() % 420)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }.joined()
            let length = (line as NSString).length
            // Mostly valid ranges, now and then ones that stick out or are empty: the builder may not trust its caller.
            let ranges = (0..<Int(rng.next() % 4)).map { _ -> Range<Int> in
                let lo = Int(rng.next() % UInt64(length + 3)), len = Int(rng.next() % 6)
                return lo..<lo + len
            }.sorted { $0.lowerBound < $1.lowerBound }
            let s = SearchSnippet.make(line: line, ranges: ranges)
            let textLength = (s.text as NSString).length
            for h in s.highlights { #expect(h.lowerBound >= 0 && h.upperBound <= textLength && !h.isEmpty) }
            for r in ranges where r.upperBound <= length && !r.isEmpty {
                if let h = s.highlights.first(where: { ($0.count == r.count) && (s.text as NSString).substring(with: NSRange($0)) == (line as NSString).substring(with: NSRange(r)) }) {
                    #expect(h.count == r.count)
                }
            }
        }
    }

    @Test func aMatchInsideTheIndentationKeepsItsText() {
        let s = SearchSnippet.make(line: "   x", ranges: [0..<2])
        #expect((s.text as NSString).substring(with: NSRange(s.highlights[0])) == "  ")
    }
}

// MARK: Scope

struct SearchScopeTests {
    @Test func workspaceFoldersWinOverTheLocation() {
        let ws = WorkspaceFolders(roots: [URL(filePath: "/p/a", directoryHint: .isDirectory), URL(filePath: "/p/b", directoryHint: .isDirectory)])
        let roots = SearchScope.roots(workspace: ws, location: URL(filePath: "/q/c", directoryHint: .isDirectory))
        #expect(roots.map(\.path) == ["/p/a", "/p/b"])
        #expect(SearchScope.title(of: roots) == "2 个文件夹")
    }

    @Test func nestedWorkspaceFoldersAreSearchedOnce() {
        func u(_ p: String) -> URL { URL(filePath: p, directoryHint: .isDirectory) }
        let ws = WorkspaceFolders(roots: [u("/p/project/notes"), u("/p/project"), u("/p/other"), u("/p/project-x")])
        #expect(SearchScope.roots(workspace: ws, location: nil).map(\.path) == ["/p/project", "/p/other", "/p/project-x"])
        #expect(SearchScope.outermost([u("/a"), u("/a")]).map(\.path) == ["/a"])
        #expect(SearchScope.outermost([u("/a/b/c"), u("/a/b")]).map(\.path) == ["/a/b"])
    }

    @Test func browseModeSearchesTheCurrentLocationUnlessItIsTooBroad() {
        let none = WorkspaceFolders()
        #expect(SearchScope.roots(workspace: none, location: URL(filePath: "/Users/me/Notes", directoryHint: .isDirectory)).map(\.path) == ["/Users/me/Notes"])
        #expect(SearchScope.roots(workspace: none, location: nil).isEmpty)
        #expect(SearchScope.roots(workspace: none, location: URL(filePath: "/", directoryHint: .isDirectory)).isEmpty)
        #expect(SearchScope.roots(workspace: none, location: URL(filePath: "/Users", directoryHint: .isDirectory)).isEmpty)
        #expect(SearchScope.title(of: [URL(filePath: "/Users/me/Notes")]) == "Notes")
    }
}

// MARK: The backend

private func run(_ query: SearchQuery, in root: URL) async -> (hits: [SearchHit], error: (any Error)?) {
    await run(BuiltinSearchBackend(), query, in: root)
}

private func run(_ backend: BuiltinSearchBackend, _ query: SearchQuery, in root: URL) async -> (hits: [SearchHit], error: (any Error)?) {
    var hits: [SearchHit] = []
    do {
        for try await hit in backend.search(query, in: root) { hits.append(hit) }
        return (hits, nil)
    } catch {
        return (hits, error)
    }
}

private func names(_ hits: [SearchHit], root: URL) -> [String] {
    hits.map { "\($0.file.lastPathComponent):\($0.line ?? 0)" }
}

struct BuiltinSearchBackendTests {
    @Test func findsLinesWithNumbersColumnsAndSnippets() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md", "# Title\n\nsome Needle here\nnothing\nneedle again, NEEDLE\n")
        let (hits, error) = await run(SearchQuery(text: "needle"), in: t.url)
        #expect(error == nil)
        #expect(hits.map(\.line) == [3, 5])
        #expect(hits[0].columns == 5..<11)
        #expect(hits[0].snippet == "some Needle here")
        #expect(hits[0].highlights == [5..<11])
        #expect(hits[1].highlights == [0..<6, 14..<20])
        #expect(hits.allSatisfy { $0.source == "builtin" })
    }

    @Test func hitsComeInTreeOrderFoldersFirst() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("b.md", "x"); try t.file("a.md", "x"); try t.file("sub/z.md", "x"); try t.file("file10.md", "x"); try t.file("file2.md", "x")
        let (hits, _) = await run(SearchQuery(text: "x"), in: t.url)
        #expect(names(hits, root: t.url) == ["z.md:1", "a.md:1", "b.md:1", "file2.md:1", "file10.md:1"])
    }

    @Test func lineNumbersMatchTheEditorForCRAndCRLF() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("crlf.md", "one\r\ntwo\r\nhit\r\n")
        try t.file("cr.md", "one\rtwo\rhit\r")
        try t.file("mixed.md", "one\n\r\nhit\n")  // LF, then CRLF: three lines
        let (hits, _) = await run(SearchQuery(text: "hit"), in: t.url)
        #expect(Set(names(hits, root: t.url)) == ["crlf.md:3", "cr.md:3", "mixed.md:3"])
        #expect(hits.allSatisfy { $0.snippet == "hit" })
    }

    @Test func aByteOrderMarkDoesNotShiftColumns() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try Data([0xEF, 0xBB, 0xBF] + Array("hello world\n".utf8)).write(to: t.url.appending(path: "bom.md"))
        let (hits, _) = await run(SearchQuery(text: "world"), in: t.url)
        #expect(hits.first?.columns == 6..<11)
    }

    @Test func ignoredFoldersAreSkippedEvenWithShowAllFiles() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("keep.md", "needle"); try t.file("sub/keep.md", "needle")
        for ignored in [".git/x.md", "node_modules/x.md", "_site/x.md", "_freeze/x.md", "report_files/x.md", "deep/node_modules/y.md", ".quarto/x.md"] {
            try t.file(ignored, "needle")
        }
        for all in [false, true] {
            let (hits, _) = await run(SearchQuery(text: "needle", files: FileTreeOptions(showAllFiles: all)), in: t.url)
            #expect(Set(names(hits, root: t.url)) == ["keep.md:1"], "showAllFiles \(all)")
            #expect(hits.count == 2)
        }
    }

    @Test func onlyTheMarkdownFamilyUnlessShowAllFiles() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for name in ["a.md", "b.markdown", "c.qmd", "d.txt", "e.json", "f.swift", ".hidden.md"] { try t.file(name, "needle") }
        let few = await run(SearchQuery(text: "needle"), in: t.url).hits
        #expect(Set(few.map(\.file.lastPathComponent)) == ["a.md", "b.markdown", "c.qmd", "d.txt"])
        let all = await run(SearchQuery(text: "needle", files: FileTreeOptions(showAllFiles: true)), in: t.url).hits
        #expect(Set(all.map(\.file.lastPathComponent)) == ["a.md", "b.markdown", "c.qmd", "d.txt", "e.json", "f.swift", ".hidden.md"])
    }

    @Test func binaryEmptyAndNonUTF8FilesAreSkipped() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try Data("needle".utf8 + [0, 1, 2]).write(to: t.url.appending(path: "bin.md"))
        try Data([0xFF, 0xFE, 0x6E, 0x00]).write(to: t.url.appending(path: "utf16.md"))
        try Data([0x6E, 0x65, 0xE9]).write(to: t.url.appending(path: "latin1.md"))
        try t.file("empty.md", ""); try t.file("ok.md", "needle")
        let (hits, error) = await run(SearchQuery(text: "needle"), in: t.url)
        #expect(error == nil)
        #expect(hits.map(\.file.lastPathComponent) == ["ok.md"])
    }

    @Test func filesOverTheSizeCapAreSkipped() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("small.md", "needle")
        try t.file("big.md", "needle" + String(repeating: " padding", count: 100))
        let backend = BuiltinSearchBackend(maxFileBytes: 100)
        let (hits, error) = await run(backend, SearchQuery(text: "needle"), in: t.url)
        #expect(error == nil)
        #expect(hits.map(\.file.lastPathComponent) == ["small.md"])
        #expect(await run(SearchQuery(text: "needle"), in: t.url).hits.count == 2)  // the default cap is 5 MB
    }

    @Test func phraseExclusionCJKAndDiacriticsEndToEnd() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md", "the quick brown fox\nquick fox jumps\n全文搜索很快\nCafé crème\n")
        let phrase = await run(SearchQuery(text: #""quick brown""#), in: t.url).hits
        #expect(phrase.map(\.line) == [1])
        let excluded = await run(SearchQuery(text: "fox -brown"), in: t.url).hits
        #expect(excluded.map(\.line) == [2])
        #expect(await run(SearchQuery(text: "搜索"), in: t.url).hits.map(\.line) == [3])
        #expect(await run(SearchQuery(text: "cafe creme"), in: t.url).hits.map(\.line) == [4])
        let regex = await run(SearchQuery(text: #"qu\w+k\s+(brown|fox)"#, isRegex: true), in: t.url).hits
        #expect(regex.map(\.line) == [1, 2])
        // ^ and $ are the line's ends
        let anchored = await run(SearchQuery(text: "^quick", isRegex: true), in: t.url).hits
        #expect(anchored.map(\.line) == [2])
    }

    @Test func anInvalidRegexEndsTheStreamWithAClearError() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md", "x(")
        let (hits, error) = await run(SearchQuery(text: "x(", isRegex: true), in: t.url)
        #expect(hits.isEmpty)
        #expect(error as? SearchError == .invalidRegex)
    }

    @Test func theHitCapStopsTheSearchAndSaysSo() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a.md", (0..<10).map { "hit \($0)" }.joined(separator: "\n"))
        try t.file("b.md", "hit")
        let capped = await run(SearchQuery(text: "hit", limit: 5), in: t.url)
        #expect(capped.hits.count == 5)
        #expect(capped.error as? SearchError == .truncated(.hits(5)))
        // exactly as many hits as the cap is not "cut short"
        let exact = await run(SearchQuery(text: "hit", limit: 11), in: t.url)
        #expect(exact.hits.count == 11 && exact.error == nil)
    }

    @Test func theFileCapStopsTheSearchAndSaysSo() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        for i in 0..<10 { try t.file("n\(i).md", "needle") }
        let (hits, error) = await run(BuiltinSearchBackend(maxFiles: 4), SearchQuery(text: "needle"), in: t.url)
        #expect(hits.count == 4)
        #expect(error as? SearchError == .truncated(.files(4)))
    }

    @Test func aSymlinkLoopIsReadOnce() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("a/x.md", "needle")
        try FileManager.default.createSymbolicLink(at: t.url.appending(path: "a/loop"), withDestinationURL: t.url)
        let (hits, error) = await run(SearchQuery(text: "needle"), in: t.url)
        #expect(error == nil)
        #expect(hits.count == 1)
    }

    @Test func aMissingFolderIsNoHitsNotAnError() async {
        let (hits, error) = await run(SearchQuery(text: "x"), in: URL(filePath: "/nonexistent-\(UUID().uuidString)", directoryHint: .isDirectory))
        #expect(hits.isEmpty && error == nil)
    }

    @Test func cancellingStopsTheWalk() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.bigDirectory { _ in "needle\n" }
        let backend = BuiltinSearchBackend()
        var count = 0
        for try await _ in backend.search(SearchQuery(text: "needle", limit: 10_000), in: t.url) {
            count += 1
            backend.cancel()
        }
        #expect(count >= 1 && count < 5000)
    }

    @Test func breakingOutOfTheLoopCancelsTheSearch() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.bigDirectory { _ in "needle\n" }
        let backend = BuiltinSearchBackend()
        let stream = backend.search(SearchQuery(text: "needle", limit: 10_000), in: t.url)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first != nil)
        // dropping the stream must not leave work running: a new search right after still works and sees every file
        let again = await run(backend, SearchQuery(text: "needle", limit: 10_000), in: t.url)
        #expect(again.hits.count == 5000)
    }
}

// MARK: Performance

struct SearchPerformanceTests {
    /// 5,050 entries: 5,000 notes of ~40 lines each, the needle in a few of them (including one in a folder).
    @Test func aBigWorkspaceReturnsFirstResultsQuicklyAndFinishes() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let paragraph = "The quick brown fox jumps over the lazy dog, 全文搜索 should stay fast on long notes. Café crème, lorem ipsum dolor sit amet."
        try t.bigDirectory { i in
            (0..<40).map { line in
                i % 500 == 7 && line == 20 ? "## Heading with unique-needle-token \(i)" : "\(line): \(paragraph) \(i)"
            }.joined(separator: "\n")
        }
        try t.file("folder-3/deep.md", "deep unique-needle-token\n")

        let backend = BuiltinSearchBackend()
        let clock = ContinuousClock()

        // A rare word: the quick reject has to discard 5,000 files.
        let start = clock.now
        var first: Duration?
        var rare = 0
        for try await _ in backend.search(SearchQuery(text: "unique-needle-token"), in: t.url) {
            if first == nil { first = clock.now - start }
            rare += 1
        }
        let rareTotal = clock.now - start
        #expect(rare == 11)  // ten notes + the deep one

        // A common word: a hit on every line of every note, capped at 1,000.
        let common = clock.now
        var firstCommon: Duration?
        var n = 0
        do {
            for try await _ in backend.search(SearchQuery(text: "lazy dog"), in: t.url) {
                if firstCommon == nil { firstCommon = clock.now - common }
                n += 1
            }
        } catch let SearchError.truncated(limit) { #expect(limit == .hits(1000)) }
        let commonTotal = clock.now - common

        // A regex over every line of every file (no quick reject): scan all 5,050 entries.
        let regexStart = clock.now
        var regexHits = 0
        for try await _ in backend.search(SearchQuery(text: #"unique-needle-token \d+$"#, isRegex: true), in: t.url) { regexHits += 1 }
        let regexTotal = clock.now - regexStart
        #expect(regexHits == 10)

        print("search 5,050 entries: rare word first \(first!) total \(rareTotal); common word first \(firstCommon!) total \(commonTotal) (\(n) hits); regex total \(regexTotal)")
        #expect(first! < .seconds(3) && firstCommon! < .seconds(1) && rareTotal < .seconds(10) && regexTotal < .seconds(30))
    }
}

/// A tiny seeded generator, so the fuzz test is the same on every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
