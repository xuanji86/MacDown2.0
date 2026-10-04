import AppKit
import ExtensionAPI
import Testing
@testable import EditorKit

@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A view without a window: no layout, no input method, but the full highlighting stack.
@MainActor
struct ViewTests {
    func makeView(_ text: String) -> MarkdownTextView { Self.makeSizedView(text) }

    /// Without a frame the text container is 0 wide and TextKit 2 lays out one character per line: unrealistically slow.
    static func makeSizedView(_ text: String) -> MarkdownTextView {
        _ = NSApplication.shared
        let (scrollView, textView) = MarkdownTextView.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        textView.string = text
        return textView
    }

    func foreground(_ view: MarkdownTextView, at location: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @Test func viewIsTextKit2() {
        let view = makeView("")
        #expect(view.textLayoutManager != nil)
        #expect(view.textContentStorage != nil)
    }

    @Test func editorDefaultsToDarkAndTheLightThemeIsSelectable() async throws {
        let view = makeView("# Hi\n")
        #expect(view.theme.name == "MacDown Classic")
        #expect(view.backgroundColor == EditorTheme.classic.background)
        view.theme = .light
        #expect(view.backgroundColor == EditorTheme.light.background)
        #expect(view.appearance?.name == .aqua)
        let light = EditorTheme.light
        #expect(await eventually { foreground(view, at: 2) == light.tokens[.heading]?.color })
    }

    @Test func styledTextLandsInTheTextStorage() async throws {
        let view = makeView("# Hi **b**\n\nplain\n")
        view.theme = .dark  // a theme without heading sizes
        let theme = view.theme
        let styled = await eventually { foreground(view, at: 2) == theme.tokens[.heading]?.color }
        #expect(styled)
        let storage = try #require(view.textStorage)
        // "b" is inside a heading and strong: bold accumulates on top of the heading's bold, colour stays heading's.
        let font = try #require(storage.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(foreground(view, at: 13) == theme.text)  // "plain"
        // Only theme attributes are ever written: no size changes (PLAN 4.3.2).
        #expect(font.pointSize == theme.font.pointSize)
    }

    @Test func aFlavorOverlayIsPaintedOverTheHighlightingAndRemovedAgain() async throws {
        let view = makeView("# Title\n\n::: {.note}\ntext {{< var x >}}\n:::\n")
        let theme = view.theme
        var seen: [(lines: [String], first: Int)] = []
        view.decorations = { lines, first in
            seen.append((lines.map(String.init), first))
            return lines.enumerated().flatMap { i, line -> [DecorationSpan] in
                var out: [DecorationSpan] = []
                if line.hasPrefix(":::") { out.append(DecorationSpan(line: first + i, columns: 0..<line.utf16.count, token: "quartoDiv")) }
                if let r = line.range(of: "{{< var x >}}") {
                    let start = line.utf16.distance(from: line.startIndex, to: r.lowerBound)
                    out.append(DecorationSpan(line: first + i, columns: start..<(start + 13), token: "quartoShortcode"))
                }
                out.append(DecorationSpan(line: first + i, columns: 0..<1, token: "notAKind"))  // unknown names are ignored
                return out
            }
        }
        let div = try #require(theme.tokens[.quartoDiv]?.color)
        let shortcode = try #require(theme.tokens[.quartoShortcode]?.color)
        #expect(await eventually { foreground(view, at: 11) == div })  // ":::" on line 2 (offset 9 = ":", 11 = third ":")
        #expect(await eventually { foreground(view, at: 26) == shortcode })  // inside "{{< var x >}}" on line 3
        #expect(foreground(view, at: 21) == theme.text)  // "text " before it is untouched
        #expect(foreground(view, at: 2) == theme.tokens[.heading]?.color)  // tree-sitter styling is still there
        // Whole lines, numbered from the document start, whatever chunk is being styled.
        #expect(seen.contains { s in s.lines.firstIndex(of: "::: {.note}").map { $0 + s.first } == 2 })

        view.decorations = nil
        #expect(await eventually { foreground(view, at: 11) != div })
        #expect(foreground(view, at: 26) != shortcode)
    }

    @Test func overlayLandsOnLinesThatStraddleAChunkBoundary() async throws {
        // Chunks are 1024 UTF-16 units; 6-unit lines put a boundary inside line 170 (offsets 1020..1024, then "\n").
        let view = makeView(String(repeating: "::: x\n", count: 300))
        var lineNumbers = Set<Int>()
        view.decorations = { lines, first in
            lines.indices.map { i in
                lineNumbers.insert(first + i)
                return DecorationSpan(line: first + i, columns: 0..<5, token: "quartoDiv")
            }
        }
        let div = try #require(view.theme.tokens[.quartoDiv]?.color)
        #expect(await eventually { foreground(view, at: 1020) == div && foreground(view, at: 1023) == div && foreground(view, at: 1024) == div })
        #expect(foreground(view, at: 1025) == view.theme.text)  // the newline after the line is not covered
        #expect(lineNumbers.contains(170) && lineNumbers.max()! < 300)
    }

    @Test func typingRestylesTheWholeParagraph() async throws {
        let view = makeView("a *b c* d\n")
        let em = view.theme.tokens[.emphasis]
        #expect(await eventually {
            (view.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
        })
        // Break the emphasis by deleting the opening `*`: the italic far from the edit must go away.
        view.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        #expect(await eventually {
            (view.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == false
        })
        _ = em
    }

    /// One paragraph several times longer than the ±4096 window a restyle used to be limited to: the far end is styled
    /// when it scrolls into view, so what it shows then is the test.
    @Test func typingRestylesAParagraphLongerThanTheOldCap() async throws {
        let view = makeView("*" + String(repeating: "word ", count: 2_399) + "word*\n")  // 12,001 units
        func isItalic(_ location: Int) -> Bool {
            (view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
        }
        func show(_ location: Int) {
            view.scrollRangeToVisible(NSRange(location: location, length: 1))
            view.enclosingScrollView?.layoutSubtreeIfNeeded()
        }
        let far = 11_000
        #expect(await eventually { isItalic(5) })
        show(far)
        #expect(await eventually { isItalic(far) }, "the far end is italic while the emphasis is closed")
        show(0)
        // Delete the opening `*`: no emphasis any more, anywhere in the paragraph.
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        #expect(await eventually { !isItalic(5) })
        show(far)
        #expect(await eventually { !isItalic(far) }, "the far end must be restyled, not keep its italic")
    }

    @Test func nothingIsWrittenWhileTextIsMarked() async throws {
        let view = makeView("# Hi\n")
        let theme = view.theme
        #expect(await eventually { foreground(view, at: 2) == theme.tokens[.heading]?.color })

        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 4, length: 0))
        try #require(view.hasMarkedText(), "headless NSTextView should accept marked text")
        let highlighter = try #require(view.highlighter)

        var refused = false
        highlighter.provideTokens(for: NSRange(location: 0, length: 9)) { result in
            if case .failure(HighlightError.markedText) = result { refused = true }
        }
        #expect(refused)
        #expect(highlighter.needsRepaintAfterComposition)

        // Even with the attributes cleared by hand, nothing re-styles during composition...
        view.textStorage?.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: 4))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(foreground(view, at: 2) == theme.text)

        // ...and the repaint happens once the composition ends.
        view.unmarkText()
        #expect(await eventually { foreground(view, at: 2) == theme.tokens[.heading]?.color })
        #expect(!highlighter.needsRepaintAfterComposition)
    }
}
