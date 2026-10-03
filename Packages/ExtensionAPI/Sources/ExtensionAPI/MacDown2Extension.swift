import Foundation
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

public struct ExtensionID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// A built-in optional extension (Quarto, qmd search). Compiled into the app; the user can only switch it on or off.
@MainActor
public protocol MacDown2Extension: AnyObject {
    static var id: ExtensionID { get }
    static var displayName: LocalizedStringResource { get }
    static var summary: LocalizedStringResource { get }
    static var enabledByDefault: Bool { get }
    /// Must be cheap: no probing for external tools, no processes, no login-shell environment.
    init()
    /// Registers flavors etc. with `host`. Same rule as `init`: probing waits until a feature is actually used.
    func activate(host: any ExtensionHost) async
    /// Idempotent: stops everything this extension started. Registrations are revoked by the host.
    func deactivate() async
    func settingsPane() -> AnyView?
}

extension MacDown2Extension {
    public func settingsPane() -> AnyView? { nil }
}

/// What an extension may register. The app gives each extension its own scoped host.
@MainActor
public protocol ExtensionHost: AnyObject {
    func register(flavor: any DocumentFlavor)
    var settings: ExtensionSettingsStore { get }
}

/// A document flavor contributed by an extension. `id` and `renderChunks` must match `flavors.json`.
public protocol DocumentFlavor: Sendable {
    var id: FlavorID { get }
    func matches(contentType: UTType) -> Bool
    var renderChunks: [String] { get }
    var previewStylesheets: [String] { get }
}

/// Per-extension preferences; keys are namespaced as `extension.<id>.<key>`.
@MainActor
public final class ExtensionSettingsStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults, extension id: ExtensionID) {
        self.defaults = defaults
        prefix = "extension.\(id.rawValue)."
    }

    public func bool(_ key: String) -> Bool? { defaults.object(forKey: prefix + key) as? Bool }
    public func set(_ value: Bool, for key: String) { defaults.set(value, forKey: prefix + key) }
}
