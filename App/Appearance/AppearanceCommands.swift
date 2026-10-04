import EditorKit
import SwiftUI
import WebAssets

/// `@AppStorage` keys of the two independent appearance choices. Defaults are the original MacDown look: a dark editor
/// next to a white preview, neither following the system until the user asks.
enum AppearanceKey {
    static let editorTheme = "editorTheme"
    static let editorThemeFollowsSystem = "editorThemeFollowsSystem"
    static let previewStyle = PreviewStyles.styleKey
    static let previewStyleFollowsSystem = PreviewStyles.followsSystemKey
}

enum AppearanceDefault {
    static let editorTheme = EditorTheme.default.name  // "MacDown Classic"
    static let previewStyle = PreviewStyles.defaultID  // "github" (white)
}

/// View ▸ Editor Theme / Preview Style: pick one, plus a Follow System switch that swaps in the pick's light/dark partner by itself.
struct AppearanceCommands: Commands {
    @AppStorage(AppearanceKey.editorTheme, store: AppDefaults.store) private var editorTheme = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem, store: AppDefaults.store) private var editorFollows = false
    @AppStorage(AppearanceKey.previewStyle, store: AppDefaults.store) private var previewStyle = AppearanceDefault.previewStyle
    @AppStorage(AppearanceKey.previewStyleFollowsSystem, store: AppDefaults.store) private var previewFollows = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Menu("Editor Theme") {
                Picker("Editor Theme", selection: $editorTheme) {
                    ForEach(ThemeLibrary.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Follow System", isOn: $editorFollows)
            }
            Menu("Preview Style") {
                Picker("Preview Style", selection: $previewStyle) {
                    ForEach(PreviewStyles.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Follow System", isOn: $previewFollows)
            }
        }
    }
}
