import SwiftUI

/// What the focused document window offers its menus (published with `focusedSceneValue`).
struct WindowActions {
    let editor: EditorHandle
    let layout: SplitLayout
    let setLayout: (SplitLayout) -> Void
    let copyHTML: () -> Void

    var editorEnabled: Bool { layout.showsEditor }
    func cycleLayout() { setLayout(layout.cycled) }
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}
