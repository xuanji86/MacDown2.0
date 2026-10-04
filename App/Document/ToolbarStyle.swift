import AppKit
import SwiftUI

/// Settings ▸ Editor ▸ Window ▸ "Toolbar style". Minimal (the default) is one compact title-bar row with the tab strip right
/// below it; Classic keeps the original two rows (a centred title, then the toolbar). Applied live: the window's own
/// `toolbarStyle` is switched, so no relaunch is needed.
enum ToolbarStyle: String, CaseIterable, Identifiable {
    case minimal
    case classic

    static let key = "window.toolbarStyle"
    static let `default` = ToolbarStyle.minimal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .minimal: "Minimal"
        case .classic: "Classic"
        }
    }

    var windowStyle: NSWindow.ToolbarStyle {
        switch self {
        case .minimal: .unifiedCompact
        case .classic: .expanded
        }
    }

    /// The tab strip's height (design "P3 Minimal": 28 pt; Classic: 34 pt).
    var tabBarHeight: CGFloat { self == .minimal ? 28 : 34 }
}
