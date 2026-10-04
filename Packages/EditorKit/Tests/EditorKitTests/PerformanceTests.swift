import AppKit
import Foundation
import Testing
@testable import EditorKit

/// S4: 1 MB document, viewport-sized highlight on the main thread. PLAN budget: < 8 ms. The budget applies to
/// optimised builds (`swift test -c release -Xswiftc -enable-testing`); a debug build runs unoptimised C and Swift, so
/// it only gets a looser sanity bound. Numbers are printed (`PERF ...`) for the PR description.
/// Opt-in (`MD2_PERF=1`; `make perf` runs them in release): they build 1 MB documents, which `make test` skips.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MD2_PERF"] == "1", "set MD2_PERF=1 (make perf)"))
struct PerformanceTests {
    #if DEBUG
    static let budgetMs = 200.0
    #else
    static let budgetMs = 8.0
    #endif

    /// A viewport is ~60 lines of ~80 columns, i.e. about 5 KB; Neon's highlighter asks for it chunk by chunk.
    static let viewportChunks = 5

    /// ~1 MiB (UTF-16 units) of realistic Markdown: headings, wrapped paragraphs with inline markup, lists,
    /// quotes, fenced code, tables, some CJK.
    static func megabyteDocument() -> String {
        var out = ""
        var length = 0
        var i = 0
        while length < 1_048_576 {
            i += 1
            let section = """
            ## Section \(i)

            Lorem ipsum **dolor** sit amet, _consectetur_ adipiscing `elit`, sed do [eiusmod](https://example.com/\(i)) tempor
            incididunt ut labore et ~~dolore~~ magna aliqua. 中文段落 **加粗** 与 `代码` 混排 \(i).

            - item one with *emphasis*
            - [x] done item `code`
            - item three [link](http://a.b/c)

            > quoted text with **strong** words
            > and a second line

            ```swift
            let value\(i) = compute(\(i))
            ```

            | a | b | c |
            |---|---|---|
            | 1 | 2 | \(i) |


            """
            out += section
            length += (section as NSString).length
        }
        return out
    }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    func f(_ x: Double) -> String { String(format: "%.2f", x) }

    /// Start offsets of viewports spread over the document, all inside Neon's synchronous zone (< 1,000,000).
    func viewportStarts(in text: String) -> [Int] {
        [0.0, 0.25, 0.5, 0.75].map { (text as NSString).lineRange(for: NSRange(location: Int(950_000 * $0), length: 0)).location }
    }

    @Test func tokensForAViewportOfAOneMegabyteDocument() async throws {
        let text = Self.megabyteDocument()
        let h = try await EngineHarness(text)
        let chunk = MarkdownHighlightEngine.synchronousLimit
        var samples: [Double] = []
        var tokenCount = 0
        for start in viewportStarts(in: text) {
            for _ in 0..<15 {
                let t = ContinuousClock.now
                tokenCount = 0
                for c in 0..<Self.viewportChunks {
                    h.engine.tokens(in: NSRange(location: start + c * chunk, length: chunk), mode: .synchronous) {
                        if case .success(let tokens) = $0 { tokenCount += tokens.count }
                    }
                }
                samples.append(ms(ContinuousClock.now - t))
            }
        }
        #expect(tokenCount > 0)
        print("PERF 1MB doc, tree-sitter only, one viewport (\(Self.viewportChunks) x \(chunk) units): median \(f(Self.median(samples))) ms, max \(f(samples.max()!)) ms, ~\(tokenCount) tokens")
        #expect(Self.median(samples) < Self.budgetMs)
    }

    @Test func paintAViewportInAWindowlessTextView() async throws {
        let text = Self.megabyteDocument()
        let view = ViewTests.makeSizedView(text)
        let highlighter = try #require(view.highlighter)
        // The first request completes only after the 1 MB parse (a background job) is done.
        let parseStart = ContinuousClock.now
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            highlighter.provideTokens(for: NSRange(location: 0, length: 100)) { _ in done.resume() }
        }
        let parseMs = ms(ContinuousClock.now - parseStart)

        let chunk = MarkdownHighlightEngine.synchronousLimit
        var samples: [Double] = []
        for start in viewportStarts(in: text) {
            for _ in 0..<10 {
                let t = ContinuousClock.now
                var finished = 0
                for c in 0..<Self.viewportChunks {
                    highlighter.provideTokens(for: NSRange(location: start + c * chunk, length: chunk)) { result in
                        if case .success = result { finished += 1 }
                    }
                }
                samples.append(ms(ContinuousClock.now - t))
                #expect(finished == Self.viewportChunks, "viewport chunks must complete synchronously once the parse is idle")
            }
        }
        print("PERF 1MB doc, view: parse after open \(f(parseMs)) ms (background); query + attribute writes for one viewport: median \(f(Self.median(samples))) ms, max \(f(samples.max()!)) ms")
        // Dominated by TextKit 2's per-edit bookkeeping on the text storage (one editing pass per chunk), not by
        // tree-sitter (see the test above), and PLAN sets no budget for it: only a sanity bound against regressions.
        #expect(Self.median(samples) < Self.budgetMs * 6)
    }

    @Test func keystrokeHandlingInAOneMegabyteDocument() async throws {
        let view = ViewTests.makeSizedView(Self.megabyteDocument())
        let highlighter = try #require(view.highlighter)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            highlighter.provideTokens(for: NSRange(location: 0, length: 100)) { _ in done.resume() }
        }
        let storage = try #require(view.textStorage)
        var samples: [Double] = []
        for k in 0..<10 {
            storage.replaceCharacters(in: NSRange(location: 500_000 + k, length: 0), with: "x")
            samples.append(ms(highlighter.lastEditHandling))
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The system's own cost of the edit (TextKit 2 shifting its element cache) is not ours and not measured here.
        print("PERF 1MB doc, our main-thread work per keystroke (snapshot + points + tree-sitter hand-off): median \(f(Self.median(samples))) ms, max \(f(samples.max()!)) ms")
        #expect(Self.median(samples) < Self.budgetMs)
    }

    /// Line numbers while scrolling a 1 MB document: only the visible fragments are enumerated, and the first one's
    /// number is a newline count. "marks" = what each scroll step costs once the viewport is laid out (the text view
    /// does that anyway), "paint" = the whole gutter drawn into a bitmap.
    @Test func lineNumbersForAViewportOfAOneMegabyteDocument() async throws {
        let view = ViewTests.makeSizedView(Self.megabyteDocument())
        var settings = EditorViewSettings()
        settings.showsLineNumbers = true
        view.apply(settings: settings)
        let gutter = try #require(view.gutter)
        let countStart = ContinuousClock.now
        let lines = view.lineCount
        let countMs = ms(ContinuousClock.now - countStart)

        var warm: [Double] = [], paint: [Double] = []
        var marks = 0
        for fraction in [0.0, 0.2, 0.4, 0.6, 0.8, 0.95] {
            view.scroll(toLine: Double(lines) * fraction)
            for _ in 0..<10 {
                var t = ContinuousClock.now
                marks = view.lineMarks(in: view.visibleRect).count
                warm.append(ms(ContinuousClock.now - t))
                gutter.frame.size.height = view.visibleRect.height
                let rep = try #require(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
                t = ContinuousClock.now
                gutter.cacheDisplay(in: gutter.bounds, to: rep)
                paint.append(ms(ContinuousClock.now - t))
            }
        }
        #expect(marks > 10 && marks < 200)
        print("PERF 1MB doc (\(lines) lines), line numbers: newline count \(f(countMs)) ms; marks for a viewport (\(marks) lines) median \(f(Self.median(warm))) ms, max \(f(warm.max()!)) ms; gutter paint median \(f(Self.median(paint))) ms, max \(f(paint.max()!)) ms")
        #expect(Self.median(warm) < Self.budgetMs)
        #expect(Self.median(paint) < Self.budgetMs * 2)
    }

    /// Switching the line spacing rewrites the paragraph style of the whole text once.
    @Test func changingTheLineSpacingInAOneMegabyteDocument() async throws {
        let view = ViewTests.makeSizedView(Self.megabyteDocument())
        var settings = EditorViewSettings()
        settings.lineSpacing = 6
        let t = ContinuousClock.now
        view.apply(settings: settings)
        let took = ms(ContinuousClock.now - t)
        print("PERF 1MB doc, line spacing change (whole-text paragraph style + viewport restyle request): \(f(took)) ms")
        #expect(took < 1000)
    }
}
