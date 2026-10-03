import AppKit
import Testing
@testable import EditorKit

struct ThemeFontOverrideTests {
    @Test func replacesOnlyTheFont() {
        let theme = EditorTheme.default.withFont(name: "Menlo-Regular", size: 17)
        #expect(theme.font.fontName == "Menlo-Regular" && theme.font.pointSize == 17)
        #expect(theme.name == EditorTheme.default.name && theme.background == EditorTheme.default.background)
    }

    @Test func emptyOrUnknownNameIsTheSystemMonospacedFont() {
        let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #expect(EditorTheme.default.withFont(name: "", size: 13).font == system)
        #expect(EditorTheme.default.withFont(name: "No Such Font", size: 13).font == system)
    }

    @Test func sizeIsClamped() {
        #expect(EditorTheme.default.withFont(name: "", size: 2).font.pointSize == 8)
        #expect(EditorTheme.default.withFont(name: "", size: 500).font.pointSize == 72)
    }
}
