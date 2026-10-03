import EditorKit
import SwiftUI
import WebAssets

/// `@AppStorage` keys of the two independent appearance choices. Defaults are the original MacDown look: a dark editor
/// next to a white preview, neither following the system until the user asks.
enum AppearanceKey {
    static let editorTheme = "editorTheme"
    static let editorThemeFollowsSystem = "editorThemeFollowsSystem"
    static let previewStyle = "previewStyle"
    static let previewStyleFollowsSystem = "previewStyleFollowsSystem"
}

enum AppearanceDefault {
    static let editorTheme = EditorTheme.default.name  // "Default Dark"
    static let previewStyle = PreviewStyles.defaultID  // "github" (white)
}

/// View ▸ 编辑器主题 / 预览样式: pick one, plus a 跟随系统 switch that swaps in the pick's light/dark partner by itself.
struct AppearanceCommands: Commands {
    @AppStorage(AppearanceKey.editorTheme) private var editorTheme = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var editorFollows = false
    @AppStorage(AppearanceKey.previewStyle) private var previewStyle = AppearanceDefault.previewStyle
    @AppStorage(AppearanceKey.previewStyleFollowsSystem) private var previewFollows = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Menu("编辑器主题") {
                Picker("编辑器主题", selection: $editorTheme) {
                    ForEach(ThemeLibrary.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("跟随系统", isOn: $editorFollows)
            }
            Menu("预览样式") {
                Picker("预览样式", selection: $previewStyle) {
                    ForEach(PreviewStyles.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("跟随系统", isOn: $previewFollows)
            }
        }
    }
}
