import AppKit
import Foundation
import OSLog
import WorkspaceKit

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "isolation")

/// Where the app's preferences live. Normally `UserDefaults.standard`; a Debug launch with `MACDOWN2_DEFAULTS_SUITE` set
/// (see `IsolatedLaunch`, `Scripts/run-isolated.sh`) keeps everything in that suite instead, so a test instance cannot
/// restore, rewrite or add to the user's real windows, files and recents. Release builds ignore the variables.
///
/// Everything that reads or writes a preference goes through `store` (or, in SwiftUI, `.defaultAppStorage(store)`;
/// code without a view tree passes `store:` to `@AppStorage`).
enum AppDefaults {
    static let isolation: IsolatedLaunch? = {
        #if DEBUG
        do {
            let reserved = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
            return try IsolatedLaunch(environment: ProcessInfo.processInfo.environment, reservedSuites: reserved)
        } catch {
            // Falling back to the real domain is exactly what this exists to prevent.
            fatalError("MACDOWN2_DEFAULTS_SUITE is unusable (\(error)); refusing to start on the real preferences")
        }
        #else
        return nil
        #endif
    }()

    static var isIsolated: Bool { isolation != nil }

    nonisolated(unsafe) static let store: UserDefaults = {  // UserDefaults is thread-safe; the SDK just does not say Sendable
        guard let isolation else { return .standard }
        guard let suite = UserDefaults(suiteName: isolation.suiteName) else {
            fatalError("cannot open the defaults suite \(isolation.suiteName)")
        }
        return suite
    }()

    /// The fuse: false (and logged) for a file outside `MACDOWN2_ALLOWED_ROOT` in an isolated launch; always true otherwise.
    static func permitsOpening(_ url: URL) -> Bool {
        guard let isolation, !isolation.allows(url) else { return true }
        log.error("isolated launch: refused \(url.path, privacy: .public), outside MACDOWN2_ALLOWED_ROOT (\(isolation.allowedRoot?.path ?? "unset", privacy: .public))")
        return false
    }

    /// Run once at launch, before any window or `NSDocumentController.shared` exists (the first instance of a subclass
    /// becomes the shared one).
    @MainActor static func installIsolation() {
        guard isIsolated else { return }
        _ = IsolatedDocumentController()
        precondition(NSDocumentController.shared is IsolatedDocumentController, "isolated launch: could not replace the shared document controller")
        // Windows and split views keep their frames in the app's real domain (`NSWindow Frame …`, `NSSplitView Subview
        // Frames …`) whatever the suite, and AppKit writes them as soon as a window is placed, before any view code runs.
        // Swizzling is the only hook early enough: with no autosave name set, nothing is read or written.
        swap(NSWindow.self, #selector(NSWindow.setFrameAutosaveName(_:)), #selector(NSWindow.isolated_setFrameAutosaveName(_:)))
        swap(NSWindow.self, #selector(NSWindow.saveFrame(usingName:)), #selector(NSWindow.isolated_saveFrame(usingName:)))
        swap(NSSplitView.self, #selector(setter: NSSplitView.autosaveName), #selector(NSSplitView.isolated_setAutosaveName(_:)))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original), let r = class_getInstanceMethod(cls, replacement) else {
            fatalError("isolated launch: cannot switch off frame autosave (\(original))")
        }
        method_exchangeImplementations(o, r)
    }
}

private extension NSWindow {
    @objc func isolated_setFrameAutosaveName(_ name: String) -> Bool { true }
    @objc func isolated_saveFrame(usingName name: String) {}
}

private extension NSSplitView {
    @objc func isolated_setAutosaveName(_ name: String?) {}
}

/// Keeps the system's recent-documents list (a file next to the real preferences) out of an isolated launch.
private final class IsolatedDocumentController: NSDocumentController {
    override func noteNewRecentDocument(_ document: NSDocument) {}
    override func noteNewRecentDocumentURL(_ url: URL) {}
    override var recentDocumentURLs: [URL] { [] }
    override func clearRecentDocuments(_ sender: Any?) {}
}
