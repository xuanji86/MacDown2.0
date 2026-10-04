import Foundation
import Observation
import Sparkle

/// Sparkle 2 wrapper (PLAN §4.14). Updates are EdDSA-signed zips on GitHub Releases; the app itself is only ad-hoc
/// signed (no Apple Developer account), so EdDSA is the one thing that authenticates an update.
///
/// Until `SUPublicEDKey` in Info.plist is a real key, Sparkle would refuse to start and pop an error alert at every
/// launch; so the updater is simply not started and the menu item / settings stay disabled.
@MainActor @Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    /// `latest/download/<asset>` always redirects to the newest non-prerelease, non-draft release, so every release
    /// must carry the complete appcast (Scripts/release.sh does).
    nonisolated static let feedURL = "https://github.com/xuanji86/MacDown2.0/releases/latest/download/appcast.xml"

    /// Offered in the settings picker; Sparkle's minimum is one hour.
    static let intervals: [(label: String, seconds: TimeInterval)] = [
        ("每天", 86_400), ("每周", 604_800), ("每月", 2_592_000),
    ]

    /// False while `SUPublicEDKey` is still the placeholder (or missing): a valid key is 32 bytes of base64.
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false

    var automaticallyChecks: Bool {
        didSet { if isConfigured { controller.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    var checkInterval: TimeInterval {
        didSet { if isConfigured { controller.updater.updateCheckInterval = checkInterval } }
    }

    // `controller` needs `self` as delegate, so it can only be built after `super.init()`.
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        // An isolated test launch never starts Sparkle: it keeps its own state in the app's real domain.
        isConfigured = !AppDefaults.isIsolated && key.flatMap { Data(base64Encoded: $0) }?.count == 32
        automaticallyChecks = true
        checkInterval = Self.intervals[0].seconds
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        guard isConfigured else { return }
        controller.startUpdater()
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        // Sparkle accepts any interval (e.g. set via `defaults`); snap the picker to the nearest offered one.
        checkInterval = Self.intervals.min {
            abs($0.seconds - updater.updateCheckInterval) < abs($1.seconds - updater.updateCheckInterval)
        }!.seconds
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() { if isConfigured { controller.checkForUpdates(nil) } }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }
}
