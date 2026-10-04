import AppKit
import OSLog

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "app-icon")

/// Settings > General > "App 图标". The icon itself is the Icon Composer document `AppIcon.icon`, which the system already
/// renders in all four appearances (System Settings > Appearance > Icon & widget style); `.system` leaves that alone.
/// Any other choice is a runtime override: `NSApp.applicationIconImage` with the matching rendering from `App/IconStyles/`
/// (made from the real icon by `Scripts/render-icon-variants.sh`). It changes the Dock tile and the app's own UI (About
/// panel, alerts) while the app runs and nothing on disk: `NSWorkspace.setIcon` would write into the bundle, which breaks
/// the code signature and with it Sparkle updates, so Finder and Launchpad keep following the system.
enum IconStyle: String, CaseIterable, Identifiable {
    case system, light, dark, clear, tinted

    static let key = "appIconStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "Light"
        case .dark: "Dark"
        case .clear: "Clear"
        case .tinted: "Tinted"
        }
    }

    /// The saved choice; an unknown value (a newer version's, say) means 跟随系统.
    static var current: IconStyle { IconStyle(rawValue: AppDefaults.store.string(forKey: key) ?? "") ?? .system }

    /// The icon as the Dock draws it: the rendering on a 1024 canvas with the standard 100 pt margin of a macOS icon (the
    /// renderings are full-bleed squircles, and the Dock shows an `applicationIconImage` as given). Nil for `.system`.
    var dockImage: NSImage? {
        guard self != .system, let url = Bundle.main.url(forResource: "appicon-\(rawValue)", withExtension: "png"),
              let art = NSImage(contentsOf: url) else { return nil }
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            art.draw(in: rect.insetBy(dx: 100, dy: 100))
            return true
        }
    }

    /// What the picker shows for this choice: `.system` is the bundle icon as the system draws it right now.
    var thumbnail: NSImage {
        dockImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private nonisolated(unsafe) static var applied: IconStyle?  // main thread only

    private nonisolated(unsafe) static let observer = Observer()

    /// Launch (before the first window): apply the saved choice and keep following it, so the Settings picker, or a write
    /// from anywhere else, takes effect at once. (KVO rather than `UserDefaults.didChangeNotification`, which a write from
    /// another process does not post.)
    @MainActor static func start() {
        apply(current)
        AppDefaults.store.addObserver(observer, forKeyPath: key, options: [], context: nil)
    }

    private final class Observer: NSObject {
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            DispatchQueue.main.async { MainActor.assumeIsolated { IconStyle.apply(IconStyle.current) } }
        }
    }

    @MainActor fileprivate static func apply(_ style: IconStyle) {
        guard style != applied else { return }
        applied = style
        NSApp.applicationIconImage = style.dockImage  // nil: back to the bundle's own (adaptive) icon
        log.info("app icon style \(style.rawValue, privacy: .public)")
    }
}
