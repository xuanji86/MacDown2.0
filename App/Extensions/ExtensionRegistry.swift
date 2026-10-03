import ExtensionAPI
import Foundation

/// The one place built-in extensions are listed and wired up (core packages must never import them).
@MainActor
enum AppExtensions {
    /// Quarto and qmd search join here from M1/M2.
    static let builtin: [any MacDown2Extension.Type] = []

    static let host = ExtensionHostImpl(defaults: preferences)
    static let registry = ExtensionRegistry(builtin, defaults: preferences, provider: host)

    /// Preference store shared with the Quick Look extension and CLI through the App Group suite.
    /// The suite needs the application-groups entitlement, which needs a signing team; the M0 ad-hoc build has
    /// none, so it falls back to the app's own domain. Flip `useAppGroup` once release signing exists (S8).
    static let useAppGroup = false
    static let appGroupSuite = "io.github.xuanji86.MacDown2.shared"
    static let preferences: UserDefaults = {
        guard useAppGroup, let shared = UserDefaults(suiteName: appGroupSuite) else { return .standard }
        return shared
    }()

    /// Instantiates every extension (cheap) and activates the enabled ones.
    static func start() {
        Task { await registry.start() }
    }
}
