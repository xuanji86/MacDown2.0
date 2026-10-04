import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "language")

/// Settings > General > "Language / 语言": the app's own override of the system language.
///
/// The override is the standard per-app one, the `AppleLanguages` key of the app's own preferences domain (what System
/// Settings > General > Language & Region > Applications writes too). Foundation reads it when the process starts to pick
/// the `.lproj` of every bundle, so a change shows after a relaunch. No key = follow the system. In an isolated test launch
/// `AppDefaults.store` is the throwaway suite, so the real domain is never touched there.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let key = "AppleLanguages"

    var id: String { rawValue }

    /// Languages are named in themselves, so a user who lands in the wrong one can still find theirs.
    var title: Text {
        switch self {
        case .system: Text("Follow System")
        case .english: Text(verbatim: "English")
        case .simplifiedChinese: Text(verbatim: "简体中文")  // l10n: native-name
        }
    }

    /// The saved override. Read from the app's own domain: `AppDefaults.store.array(forKey:)` would answer with the language
    /// the process runs in (the system's, or a launch argument's) even when nothing is saved.
    static var current: AppLanguage {
        let domain = AppDefaults.isolation?.suiteName ?? Bundle.main.bundleIdentifier ?? ""
        guard let saved = (AppDefaults.store.persistentDomain(forName: domain)?[key] as? [String])?.first else { return .system }
        let code = Locale.Language(identifier: saved).languageCode?.identifier
        return allCases.first { $0 != .system && Locale.Language(identifier: $0.rawValue).languageCode?.identifier == code } ?? .system
    }

    /// Writes the choice; `.system` removes the override.
    func save() {
        if self == .system {
            AppDefaults.store.removeObject(forKey: Self.key)
        } else {
            AppDefaults.store.set([rawValue], forKey: Self.key)
        }
        log.info("language override: \(rawValue.isEmpty ? "system" : rawValue, privacy: .public)")
    }
}

/// "Relaunch Now": quits through the usual path (unsaved documents are asked about, windows are saved) and, once the app really
/// is going away, starts a new instance. A cancelled quit leaves nothing behind.
@MainActor
enum AppRelauncher {
    private static var requested = false

    static func relaunch() {
        // A relaunched instance would start without the isolation variables, i.e. on the real preferences.
        guard !AppDefaults.isIsolated else {
            log.info("isolated launch: relaunch skipped")
            return
        }
        requested = true
        NSApp.terminate(nil)
    }

    /// The quit was cancelled (an unsaved document's sheet answered Cancel).
    static func cancel() { requested = false }

    /// `applicationWillTerminate`: after this process has exited, open the app again. A shell waits for the exit so the new
    /// instance never overlaps this one (it would restore windows from a record this one is still writing).
    static func launchNewInstanceIfRequested() {
        guard requested else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try waiter.run() } catch { log.error("relaunch failed: \(String(describing: error), privacy: .public)") }
    }
}
