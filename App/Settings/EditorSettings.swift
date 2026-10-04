import EditorKit
import SwiftUI

/// `@AppStorage` keys of the Editor page. Defaults are the original MacDown's (`EditorBehavior()`, `EditorViewSettings()`,
/// Menlo 14 pt), so the editor looks and behaves the same until the user changes something.
enum EditorSettingKey {
    static let fontName = "editorFontName"  // "" = system monospaced; default Menlo
    static let fontSize = "editorFontSize"
    static let autoPair = "editorAutoPair"
    static let continueLists = "editorContinueLists"
    static let autoNumberLists = "editorAutoNumberLists"
    static let tabInsertsSpaces = "editorTabInsertsSpaces"
    static let tabWidth = "editorTabWidth"
    static let listMarker = "editorListMarker"
    static let editorOnRight = "editor.onRight"  // the layout swap lives in DocumentView, not in EditorKit
}

/// The editor-side settings in one place: the editor pane reads them, the Settings page binds them.
struct EditorSettings: DynamicProperty {
    static let listMarkers = ["-", "*", "+"]
    /// The original MacDown's defaults (Menlo 14); `withFont` falls back to the system monospaced font without Menlo.
    static let defaultFontName = "Menlo"
    static let defaultFontSize = 14.0

    @AppStorage(EditorSettingKey.fontName) var fontName = EditorSettings.defaultFontName
    @AppStorage(EditorSettingKey.fontSize) var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettingKey.autoPair) var autoPair = EditorBehavior().autoPair
    @AppStorage(EditorSettingKey.continueLists) var continueLists = EditorBehavior().continueLists
    @AppStorage(EditorSettingKey.autoNumberLists) var autoNumberLists = EditorBehavior().autoNumberLists
    @AppStorage(EditorSettingKey.tabInsertsSpaces) var tabInsertsSpaces = EditorBehavior().tabInsertsSpaces
    @AppStorage(EditorSettingKey.tabWidth) var tabWidth = EditorBehavior().tabWidth
    @AppStorage(EditorSettingKey.listMarker) var listMarker = String(EditorBehavior().unorderedListMarker)
    // The rest of the page lives in EditorKit (`editor.*` keys), which also owns the defaults.
    @AppStorage(EditorViewSettings.Key.lineNumbers) var lineNumbers = EditorViewSettings().showsLineNumbers
    @AppStorage(EditorViewSettings.Key.lineSpacing) var lineSpacing = Double(EditorViewSettings().lineSpacing)
    @AppStorage(EditorViewSettings.Key.limitWidth) var limitWidth = EditorViewSettings().limitsWidth
    @AppStorage(EditorViewSettings.Key.maxWidth) var maxWidth = Double(EditorViewSettings().maxWidth)
    @AppStorage(EditorViewSettings.Key.showInvisibles) var showInvisibles = EditorViewSettings().showsInvisibles
    @AppStorage(EditorViewSettings.Key.smartHome) var smartHome = EditorViewSettings().smartHome
    @AppStorage(EditorSettingKey.editorOnRight) var editorOnRight = false

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

    var view: EditorViewSettings {
        var v = EditorViewSettings()
        v.showsLineNumbers = lineNumbers
        v.lineSpacing = CGFloat(lineSpacing)
        v.limitsWidth = limitWidth
        v.maxWidth = CGFloat(maxWidth)
        v.showsInvisibles = showInvisibles
        v.smartHome = smartHome
        return v
    }

    func apply(to theme: EditorTheme) -> EditorTheme { theme.withFont(name: fontName, size: fontSize) }
}
