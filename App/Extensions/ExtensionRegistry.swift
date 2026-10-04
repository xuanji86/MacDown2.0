import ExtensionAPI
import Foundation
import MarkdownCore
import QuartoExtension
import SwiftUI
import UniformTypeIdentifiers

/// The one place built-in extensions are listed and wired up (core packages must never import them).
@MainActor
enum AppExtensions {
    /// qmd search joins here from M2.
    static let builtin: [any MacDown2Extension.Type] = [QuartoExtension.self]

    /// Reads the login shell only when something calls `snapshot()`/`reread()`: extensions through their host, and the
    /// Settings ▸ General "re-read" button. Creating it (even at launch) starts nothing.
    static let loginShell = LoginShellEnvironment()

    static let host = ExtensionHostImpl(defaults: preferences, toolEnvironment: loginShell)
    static let registry = ExtensionRegistry(builtin, defaults: preferences, provider: host)

    /// Preference store shared with the Quick Look extension and CLI through the App Group suite.
    /// The suite needs the application-groups entitlement, which needs a signing team; the M0 ad-hoc build has
    /// none, so it falls back to the app's own domain. Flip `useAppGroup` once release signing exists (S8).
    static let useAppGroup = false
    static let appGroupSuite = "io.github.xuanji86.MacDown2.shared"
    static let preferences: UserDefaults = {
        guard !AppDefaults.isIsolated, useAppGroup, let shared = UserDefaults(suiteName: appGroupSuite) else { return AppDefaults.store }
        return shared
    }()

    /// Instantiates every extension (cheap) and activates the enabled ones.
    static func start() {
        Task { await registry.start() }
    }

    // MARK: Flavors

    /// The flavor a document file gets from the extensions that are on right now; nil = plain Markdown. Reads the
    /// observable `host.flavors`, so a view that calls this re-evaluates when an extension is switched.
    static func flavor(for fileURL: URL?) -> (any DocumentFlavor)? {
        let contentType = UTType.ofDocument(at: fileURL)
        return host.flavors.first { $0.matches(contentType: contentType) }
    }

    /// A document an extension would handle if it were on (a .qmd while Quarto is off): what to tell the user, once.
    struct DisabledHint: Equatable {
        let message: String
        /// UserDefaults key (in `preferences`) that remembers "don't remind me".
        let dismissKey: String
    }

    private static let manifest = try? FlavorManifest.bundled()

    static func disabledHint(for fileURL: URL?) -> DisabledHint? {
        let contentType = UTType.ofDocument(at: fileURL)
        guard flavor(for: fileURL) == nil,
              let entry = manifest?.entries.values.first(where: { $0.utTypes.contains(contentType.identifier) }),
              let ext = registry.ext(forSettingKey: entry.settingKey),
              !registry.isEnabled(type(of: ext).id),
              let hint = type(of: ext).disabledHint
        else { return nil }
        return DisabledHint(message: String(localized: hint), dismissKey: "\(entry.settingKey).hintDismissed")
    }

    /// `options` for rendering `markdown` as the document at `fileURL`: flavor id, chunks and the files it asks for.
    static func renderOptions(_ options: RenderOptions, markdown: String, fileURL: URL?) -> RenderOptions {
        options.rendering(as: flavor(for: fileURL), markdown: markdown, readFile: QuartoIncludes.fileReader(directory: fileURL?.deletingLastPathComponent()))
    }
}
