import ExtensionAPI
import Foundation
import Observation

/// App-side backend for the extension registry: keeps what each extension registered, drops it on revoke.
/// Observable: windows that read `flavors` while building their views re-evaluate when an extension is switched on or off
/// (PLAN 4.17: open documents re-decide their flavor and re-render).
@MainActor @Observable
final class ExtensionHostImpl: ExtensionHostProvider {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored fileprivate let toolEnvironment: any ToolEnvironment
    private var flavorRegistrations: [(owner: ExtensionID, flavor: any DocumentFlavor)] = []
    private var searchProviderRegistrations: [(owner: ExtensionID, provider: any SearchProvider)] = []

    init(defaults: UserDefaults, toolEnvironment: any ToolEnvironment) {
        self.defaults = defaults
        self.toolEnvironment = toolEnvironment
    }

    /// Flavors of all currently active extensions, in registration order (consulted when a document is opened).
    var flavors: [any DocumentFlavor] { flavorRegistrations.map(\.flavor) }

    /// Search sources of all currently active extensions (the search panel puts them before the built-in one).
    var searchProviders: [any SearchProvider] { searchProviderRegistrations.map(\.provider) }

    func host(for id: ExtensionID) -> any ExtensionHost { ScopedHost(owner: id, backend: self) }

    func revokeRegistrations(of id: ExtensionID) {
        flavorRegistrations.removeAll { $0.owner == id }
        searchProviderRegistrations.removeAll { $0.owner == id }
    }

    fileprivate func add(_ flavor: any DocumentFlavor, owner: ExtensionID) {
        flavorRegistrations.append((owner, flavor))
    }

    fileprivate func add(_ provider: any SearchProvider, owner: ExtensionID) {
        searchProviderRegistrations.append((owner, provider))
    }

    @MainActor
    private final class ScopedHost: ExtensionHost {
        let owner: ExtensionID
        unowned let backend: ExtensionHostImpl
        let settings: ExtensionSettingsStore
        var toolEnvironment: any ToolEnvironment { backend.toolEnvironment }

        init(owner: ExtensionID, backend: ExtensionHostImpl) {
            self.owner = owner
            self.backend = backend
            settings = ExtensionSettingsStore(defaults: backend.defaults, extension: owner)
        }

        func register(flavor: any DocumentFlavor) { backend.add(flavor, owner: owner) }
        func register(searchProvider: any SearchProvider) { backend.add(searchProvider, owner: owner) }
    }
}
