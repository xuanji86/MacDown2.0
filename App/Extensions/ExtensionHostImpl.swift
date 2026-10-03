import ExtensionAPI
import Foundation

/// App-side backend for the extension registry: keeps what each extension registered, drops it on revoke.
@MainActor
final class ExtensionHostImpl: ExtensionHostProvider {
    private let defaults: UserDefaults
    private var flavorRegistrations: [(owner: ExtensionID, flavor: any DocumentFlavor)] = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Flavors of all currently active extensions, in registration order (consulted when a document is opened).
    var flavors: [any DocumentFlavor] { flavorRegistrations.map(\.flavor) }

    func host(for id: ExtensionID) -> any ExtensionHost { ScopedHost(owner: id, backend: self) }

    func revokeRegistrations(of id: ExtensionID) {
        flavorRegistrations.removeAll { $0.owner == id }
    }

    fileprivate func add(_ flavor: any DocumentFlavor, owner: ExtensionID) {
        flavorRegistrations.append((owner, flavor))
    }

    @MainActor
    private final class ScopedHost: ExtensionHost {
        let owner: ExtensionID
        unowned let backend: ExtensionHostImpl
        let settings: ExtensionSettingsStore

        init(owner: ExtensionID, backend: ExtensionHostImpl) {
            self.owner = owner
            self.backend = backend
            settings = ExtensionSettingsStore(defaults: backend.defaults, extension: owner)
        }

        func register(flavor: any DocumentFlavor) { backend.add(flavor, owner: owner) }
    }
}
