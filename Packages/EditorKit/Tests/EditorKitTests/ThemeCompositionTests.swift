import AppKit
import Testing
@testable import EditorKit

/// A theme, font or line-spacing change while an input method has marked text must not touch the text storage: rewriting
/// attributes across the marked range ends the composition (the candidate window disappears and the preedit is committed
/// or lost). The change lands once the composition ends.
@MainActor
struct ThemeCompositionTests {
    private let noRange = NSRange(location: NSNotFound, length: 0)

    private func composing() throws -> MarkdownTextView {
        let view = ViewTests.makeSizedView("plain ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: noRange)
        try #require(view.hasMarkedText(), "headless NSTextView should accept marked text")
        return view
    }

    private func font(_ view: MarkdownTextView, at location: Int) -> NSFont? {
        view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func lineSpacing(_ view: MarkdownTextView, at location: Int) -> CGFloat? {
        (view.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing
    }

    @Test func aFontChangeWaitsForTheCompositionToEnd() throws {
        let view = try composing()
        let before = try #require(font(view, at: 7))
        let bigger = view.theme.withFont(name: "Menlo-Regular", size: before.pointSize + 6)
        view.theme = bigger

        #expect(view.hasMarkedText(), "the theme change must not end the composition")
        #expect(font(view, at: 7) == before, "the marked range keeps its attributes")
        #expect(font(view, at: 1) == before, "so does the rest of the text")

        view.unmarkText()
        #expect(font(view, at: 7)?.pointSize == bigger.font.pointSize)
        #expect(font(view, at: 1)?.pointSize == bigger.font.pointSize)
    }

    @Test func aLineSpacingChangeWaitsForTheCompositionToEnd() throws {
        let view = try composing()
        let before = try #require(lineSpacing(view, at: 7))
        var settings = view.viewSettings
        settings.lineSpacing = before + 6
        view.apply(settings: settings)

        #expect(view.hasMarkedText())
        #expect(lineSpacing(view, at: 7) == before)

        view.insertText("中", replacementRange: noRange)  // committing
        #expect(!view.hasMarkedText())
        #expect(lineSpacing(view, at: 1) == view.viewSettings.lineSpacing)
        #expect(lineSpacing(view, at: 6) == view.viewSettings.lineSpacing)
    }

    @Test func theChromeStillFollowsTheThemeWhileComposing() throws {
        let view = try composing()
        view.theme = .light
        #expect(view.backgroundColor == EditorTheme.light.background)
        #expect(view.hasMarkedText())
    }
}
