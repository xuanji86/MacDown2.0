import AppKit
import Testing
@testable import EditorKit

/// MacDown Classic scales headings through `fontScale` (a multiple of the body size); the scaled font must reach the
/// text storage, change the line heights, and leave the source-line scroll mapping intact.
@MainActor
struct HeadingScaleTests {
    static let text = "# One\n\n###### Six\n\nSetext\n======\n\nbody\n"

    func font(_ view: MarkdownTextView, at location: Int) -> NSFont? {
        view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    /// Point size rounded to 0.1 (the theme stores scales with 4 decimals).
    func pt(_ view: MarkdownTextView, at location: Int) -> Double {
        ((font(view, at: location)?.pointSize ?? 0) * 10).rounded() / 10
    }

    func classicView(_ text: String) -> MarkdownTextView {
        let view = ViewTests.makeSizedView(text)
        view.theme = EditorTheme.classic.withFont(name: "", size: 14)
        return view
    }

    @Test func headingTokensGetTheScaledFont() async throws {
        let view = classicView(Self.text)
        #expect(await eventually { pt(view, at: 2) == 24 })
        #expect(font(view, at: 2)?.fontDescriptor.symbolicTraits.contains(.bold) == true)  // H1 bold
        #expect(pt(view, at: 0) == 24)  // the "#" marker scales with its line
        let six = (Self.text as NSString).range(of: "Six").location
        #expect(abs((font(view, at: six)?.pointSize ?? 0) - 11) < 0.01)
        #expect(font(view, at: six)?.fontDescriptor.symbolicTraits.contains(.bold) == false)  // H6 not bold
        let setext = (Self.text as NSString).range(of: "Setext").location
        #expect(pt(view, at: setext) == 24)  // setext "===" is H1
        let body = (Self.text as NSString).range(of: "body").location
        #expect(pt(view, at: body) == 14)
    }

    @Test func scalesFollowTheBodyFontSize() async throws {
        let view = ViewTests.makeSizedView("## Two\n")
        view.theme = EditorTheme.classic.withFont(name: "", size: 20)
        #expect(await eventually { abs((font(view, at: 3)?.pointSize ?? 0) - 20 * 20 / 14) < 0.01 })
    }

    @Test func aHeadingLineIsTallerThanABodyLine() async throws {
        let view = classicView("# Big\nbody")
        #expect(await eventually { pt(view, at: 2) == 24 })
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        let content = try #require(layout.textContentManager)
        func height(at offset: Int) -> CGFloat {
            let location = content.location(content.documentRange.location, offsetBy: offset)!
            return layout.textLayoutFragment(for: location)!.layoutFragmentFrame.height
        }
        // Both lines carry the same extra line spacing (default 3 pt since the editor settings landed); compare glyph rows.
        let style = view.textStorage?.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle
        let spacing = style?.lineSpacing ?? 0
        #expect(height(at: 0) - spacing > (height(at: 6) - spacing) * 1.4)
    }

    @Test func scrollLineMappingSurvivesMixedLineHeights() async throws {
        let text = (0..<300).map { $0 % 4 == 0 ? "# Heading \($0)" : "line \($0) of the document" }.joined(separator: "\n")
        _ = NSApplication.shared
        // Keep the scroll view alive across the awaits (the view only holds it weakly).
        let (scrollView, view) = MarkdownTextView.makeScrollView(theme: EditorTheme.classic.withFont(name: "", size: 14))
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        view.string = text
        defer { withExtendedLifetime(scrollView) {} }
        do {
            #expect(await eventually { pt(view, at: 2) == 24 })
            // Headings are 24 pt among 14 pt lines: a scroll position is still a source line plus a fraction of it.
            // (TextKit 2 estimates the height of text it has not laid out, so allow a few lines of slack.)
            for line in [0.0, 40.0, 100.5] {
                view.scroll(toLine: line)
                #expect(abs(view.topVisibleLine - line) < 5, "line \(line) read back as \(view.topVisibleLine)")
            }
            view.goTo(line: 80)
            #expect(view.caretLine == 80)
        }
    }
}
