import AppKit
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
        #expect(view.theme.name == "Default Dark")
        #expect(view.backgroundColor == EditorTheme.dark.background)
        view.theme = .light
        #expect(view.backgroundColor == EditorTheme.light.background)
        #expect(view.appearance?.name == .aqua)
        let light = EditorTheme.light
        #expect(await eventually { foreground(view, at: 2) == light.tokens[.heading]?.color })
    }

    @Test func styledTextLandsInTheTextStorage() async throws {
        let view = makeView("# Hi **b**\n\nplain\n")
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
