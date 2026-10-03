import Foundation

/// App-side backend: hands each extension a scoped host and drops everything it registered.
@MainActor
public protocol ExtensionHostProvider: AnyObject {
    func host(for id: ExtensionID) -> any ExtensionHost
    func revokeRegistrations(of id: ExtensionID)
}

/// Owns the built-in extensions and their on/off switches (`extension.<id>.enabled`).
/// Disabled extensions are instantiated (cheap `init`) but never activated.
@MainActor
public final class ExtensionRegistry {
    public static func enabledKey(_ id: ExtensionID) -> String { "extension.\(id.rawValue).enabled" }

    public let extensions: [any MacDown2Extension]
    public private(set) var active: Set<ExtensionID> = []
    private let defaults: UserDefaults
    private let provider: any ExtensionHostProvider

    public init(_ types: [any MacDown2Extension.Type], defaults: UserDefaults, provider: any ExtensionHostProvider) {
        extensions = types.map { $0.init() }
        self.defaults = defaults
        self.provider = provider
    }

    public func isEnabled(_ id: ExtensionID) -> Bool {
        if let stored = defaults.object(forKey: Self.enabledKey(id)) as? Bool { return stored }
        return extensions.first { type(of: $0).id == id }.map { type(of: $0).enabledByDefault } ?? false
    }

    /// The extension whose switch is `key` (a `FlavorManifest` entry's `settingKey`).
    public func ext(forSettingKey key: String) -> (any MacDown2Extension)? {
        extensions.first { Self.enabledKey(type(of: $0).id) == key }
    }

    /// Writes the default switch for never-toggled extensions (Quick Look reads it), then activates enabled ones.
    public func start() async {
        for ext in extensions {
            let id = type(of: ext).id
            if defaults.object(forKey: Self.enabledKey(id)) == nil {
                defaults.set(type(of: ext).enabledByDefault, forKey: Self.enabledKey(id))
            }
            if isEnabled(id) { await activate(ext) }
        }
    }

    public func setEnabled(_ enabled: Bool, for id: ExtensionID) async {
        guard let ext = extensions.first(where: { type(of: $0).id == id }) else { return }
        defaults.set(enabled, forKey: Self.enabledKey(id))
        if enabled { await activate(ext) } else { await deactivate(ext) }
    }

    // `active` is updated before awaiting so a quick toggle cannot activate twice.
    private func activate(_ ext: any MacDown2Extension) async {
        let id = type(of: ext).id
        guard active.insert(id).inserted else { return }
        await ext.activate(host: provider.host(for: id))
    }

    private func deactivate(_ ext: any MacDown2Extension) async {
        let id = type(of: ext).id
        guard active.remove(id) != nil else { return }
        await ext.deactivate()
        provider.revokeRegistrations(of: id)
    }
}
