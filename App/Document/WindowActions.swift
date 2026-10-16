import SwiftUI

/// What the focused document window offers its menus (published with `focusedSceneValue`).
struct WindowActions {
    let editor: EditorHandle
    let layout: SplitLayout
    let setLayout: (SplitLayout) -> Void
    let copyHTML: () -> Void
    let exportHTML: () -> Void
    let exportPDF: () -> Void
    let printDocument: () -> Void
    let showOutline: () -> Void
    let renderPreview: () -> Void
    /// "Render with Quarto" (⌘⌥R) for a document whose flavor has a real render; nil for any other.
    var alternatePreview: AlternatePreviewCommand? = nil

    var editorEnabled: Bool { layout.showsEditor }
    func cycleLayout() { setLayout(layout.cycled) }
}

/// View ▸ Render with Quarto: the same switch as the preview bar's `Approximate | Quarto`.
struct AlternatePreviewCommand {
    let title: String
    let isOn: Bool
    let toggle: () -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}
