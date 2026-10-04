import MarkdownCore
import SwiftUI

/// The Markdown / Rendering settings, live. `RenderPreferences` (MarkdownCore) owns the values, their defaults and the
/// mapping to `RenderOptions`; this is the observable holder the Settings window edits and the preview watches.
@MainActor @Observable
final class RenderSettings {
    static let shared = RenderSettings()

    /// What to hand `JSCRenderer` right now (preview, Copy HTML, export). Reads UserDefaults, so it is always current
    /// and callable from any context.
    nonisolated static var current: RenderOptions { RenderPreferences(defaults: AppDefaults.store).options }

    var preferences = RenderPreferences(defaults: AppDefaults.store) {
        didSet { if preferences != oldValue { preferences.write(to: AppDefaults.store) } }
    }

    var options: RenderOptions { preferences.options }

    /// A switch for one syntax extension.
    func binding(_ ext: MarkdownExtension) -> Binding<Bool> {
        Binding(
            get: { self.preferences.extensions.contains(ext) },
            set: { on in
                if on { self.preferences.extensions.insert(ext) } else { self.preferences.extensions.remove(ext) }
            }
        )
    }
}
