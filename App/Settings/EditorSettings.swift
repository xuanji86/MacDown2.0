import EditorKit
import SwiftUI

/// `@AppStorage` keys of the Editor page. Defaults come from `EditorBehavior()` (the original MacDown's) and the system
/// monospaced font at 13 pt, so the editor looks and behaves the same until the user changes something.
enum EditorSettingKey {
    static let fontName = "editorFontName"  // "" = system monospaced
    static let fontSize = "editorFontSize"
    static let autoPair = "editorAutoPair"
    static let continueLists = "editorContinueLists"
    static let autoNumberLists = "editorAutoNumberLists"
    static let tabInsertsSpaces = "editorTabInsertsSpaces"
    static let tabWidth = "editorTabWidth"
    static let listMarker = "editorListMarker"
}

/// The editor-side settings in one place: the editor pane reads them, the Settings page binds them.
struct EditorSettings: DynamicProperty {
    static let listMarkers = ["-", "*", "+"]

    @AppStorage(EditorSettingKey.fontName) var fontName = ""
    @AppStorage(EditorSettingKey.fontSize) var fontSize = 13.0
    @AppStorage(EditorSettingKey.autoPair) var autoPair = EditorBehavior().autoPair
    @AppStorage(EditorSettingKey.continueLists) var continueLists = EditorBehavior().continueLists
    @AppStorage(EditorSettingKey.autoNumberLists) var autoNumberLists = EditorBehavior().autoNumberLists
    @AppStorage(EditorSettingKey.tabInsertsSpaces) var tabInsertsSpaces = EditorBehavior().tabInsertsSpaces
    @AppStorage(EditorSettingKey.tabWidth) var tabWidth = EditorBehavior().tabWidth
    @AppStorage(EditorSettingKey.listMarker) var listMarker = String(EditorBehavior().unorderedListMarker)

    var behavior: EditorBehavior {
        var b = EditorBehavior()
        b.autoPair = autoPair
        b.continueLists = continueLists
        b.autoNumberLists = autoNumberLists
        b.tabInsertsSpaces = tabInsertsSpaces
        b.tabWidth = min(max(tabWidth, 1), 8)
        if Self.listMarkers.contains(listMarker), let c = listMarker.first { b.unorderedListMarker = c }
        return b
    }

    func apply(to theme: EditorTheme) -> EditorTheme { theme.withFont(name: fontName, size: fontSize) }
}
