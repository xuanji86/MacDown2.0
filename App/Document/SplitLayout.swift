import Foundation
import SwiftUI
import WorkspaceKit

/// Which panes of a document window show and how the width is divided. Persisted per window (`@SceneStorage`) as
/// `mode` + `editorFraction`; a dragged divider just writes an arbitrary fraction.
struct SplitLayout: Equatable {
    typealias Mode = SplitMode  // in WorkspaceKit: the command line, the Settings default and the saved windows share it

    static let minFraction = 0.15, maxFraction = 0.85

    var mode: Mode = .both
    var editorFraction = 0.5

    var showsEditor: Bool { mode.showsEditor }
    var showsPreview: Bool { mode.showsPreview }

    /// Editor width in a window `total` points wide (0 when hidden); the preview gets the rest.
    func editorWidth(total: Double) -> Double {
        switch mode {
        case .both: total * min(max(editorFraction, Self.minFraction), Self.maxFraction)
        case .editorOnly: total
        case .previewOnly: 0
        }
    }

    /// Toolbar button: both -> editor only -> preview only -> both.
    var cycled: SplitLayout { SplitLayout(mode: mode.next, editorFraction: editorFraction) }
}

/// The named layouts of the toolbar menu and View menu.
enum SplitPreset: CaseIterable, Identifiable {
    case equal, editorQuarter, editorThreeQuarters, editorOnly, previewOnly

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .equal: "Editor and Preview, Equal"
        case .editorQuarter: "Editor 1/4, Preview 3/4"
        case .editorThreeQuarters: "Editor 3/4, Preview 1/4"
        case .editorOnly: "Editor Only (Hide Preview)"
        case .previewOnly: "Preview Only (Hide Editor)"
        }
    }

    var layout: SplitLayout {
        switch self {
        case .equal: SplitLayout(mode: .both, editorFraction: 0.5)
        case .editorQuarter: SplitLayout(mode: .both, editorFraction: 0.25)
        case .editorThreeQuarters: SplitLayout(mode: .both, editorFraction: 0.75)
        case .editorOnly: SplitLayout(mode: .editorOnly)
        case .previewOnly: SplitLayout(mode: .previewOnly)
        }
    }

    /// The preset `layout` is showing; nil for a divider dragged elsewhere. Hidden-pane layouts ignore the fraction.
    static func matching(_ layout: SplitLayout) -> SplitPreset? {
        allCases.first { preset in
            let p = preset.layout
            return p.mode == layout.mode && (p.mode != .both || abs(p.editorFraction - layout.editorFraction) < 0.01)
        }
    }
}
