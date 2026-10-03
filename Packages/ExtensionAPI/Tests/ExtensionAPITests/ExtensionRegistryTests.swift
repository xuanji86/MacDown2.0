import Foundation
import MarkdownCore
import Testing
import UniformTypeIdentifiers
@testable import ExtensionAPI

private struct StubFlavor: DocumentFlavor {
    var id: FlavorID = "stub"
    func matches(contentType: UTType) -> Bool { false }
    var renderChunks: [String] = []
    var previewStylesheets: [String] = []
}

@MainActor private class NoopExtension: MacDown2Extension {
    class var id: ExtensionID { "on" }
    static let displayName: LocalizedStringResource = "Noop"
    static let summary: LocalizedStringResource = "Test extension"
    class var enabledByDefault: Bool { true }
    var activations = 0
    var deactivations = 0
    required init() {}
    func activate(host: any ExtensionHost) async {
        activations += 1
        host.register(flavor: StubFlavor())
    }
    func deactivate() async { deactivations += 1 }
}

@MainActor private final class OffByDefault: NoopExtension {
    override class var id: ExtensionID { "off" }
    override class var enabledByDefault: Bool { false }
}

@MainActor private final class FakeProvider: ExtensionHostProvider {
    final class Host: ExtensionHost {
        let id: ExtensionID
        unowned let provider: FakeProvider
        let settings: ExtensionSettingsStore
        init(id: ExtensionID, provider: FakeProvider) {
            self.id = id
            self.provider = provider
            settings = ExtensionSettingsStore(defaults: provider.defaults, extension: id)
        }
        func register(flavor: any DocumentFlavor) { provider.flavors[id, default: []].append(flavor.id) }
    }
    let defaults: UserDefaults
    var flavors: [ExtensionID: [FlavorID]] = [:]
    var revoked: [ExtensionID] = []
    init(defaults: UserDefaults) { self.defaults = defaults }
    func host(for id: ExtensionID) -> any ExtensionHost { Host(id: id, provider: self) }
    func revokeRegistrations(of id: ExtensionID) {
        revoked.append(id)
        flavors[id] = nil
    }
}

@MainActor private func makeRegistry(_ defaults: UserDefaults) -> (ExtensionRegistry, FakeProvider) {
    let provider = FakeProvider(defaults: defaults)
    return (ExtensionRegistry([NoopExtension.self, OffByDefault.self], defaults: defaults, provider: provider), provider)
}

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "test.\(UUID().uuidString)")! }

@MainActor private func counts(_ registry: ExtensionRegistry, _ index: Int) -> (Int, Int) {
    let ext = registry.extensions[index] as! NoopExtension
    return (ext.activations, ext.deactivations)
}

@Test @MainActor func startActivatesOnlyEnabledAndPersistsDefaults() async {
    let defaults = freshDefaults()
    let (registry, provider) = makeRegistry(defaults)
    await registry.start()
    #expect(registry.active == ["on"])
    #expect(counts(registry, 0) == (1, 0) && counts(registry, 1) == (0, 0))
    #expect(provider.flavors == ["on": ["stub"]])
    #expect(defaults.object(forKey: "extension.on.enabled") as? Bool == true)
    #expect(defaults.object(forKey: "extension.off.enabled") as? Bool == false)
}

@Test @MainActor func storedChoiceOverridesDefault() async {
    let defaults = freshDefaults()
    defaults.set(false, forKey: ExtensionRegistry.enabledKey("on"))
    defaults.set(true, forKey: ExtensionRegistry.enabledKey("off"))
    let (registry, _) = makeRegistry(defaults)
    await registry.start()
    #expect(registry.active == ["off"])
}

@Test @MainActor func togglingIsPersistedIdempotentAndRevokes() async {
    let defaults = freshDefaults()
    let (registry, provider) = makeRegistry(defaults)
    await registry.start()

    await registry.setEnabled(false, for: "on")
    await registry.setEnabled(false, for: "on")
    #expect(counts(registry, 0) == (1, 1))
    #expect(provider.revoked == ["on"] && provider.flavors.isEmpty)
    #expect(defaults.bool(forKey: "extension.on.enabled") == false)

    await registry.setEnabled(true, for: "off")
    await registry.setEnabled(true, for: "off")
    #expect(counts(registry, 1) == (1, 0))
    #expect(registry.active == ["off"])

    let (reloaded, _) = makeRegistry(defaults)
    await reloaded.start()
    #expect(reloaded.active == ["off"])
}

private struct FileFlavor: DocumentFlavor {
    var id: FlavorID = "files"
    func matches(contentType: UTType) -> Bool { false }
    var renderChunks = ["files.chunk.js"]
    var previewStylesheets: [String] = []
    func auxiliaryFiles(for markdown: String, readFile: (String) -> String?) -> [String: String] {
        readFile(markdown).map { [markdown: $0] } ?? [:]
    }
}

@Test func optionsFollowTheFlavorAndPlainMarkdownLeavesThemAlone() {
    let base = RenderOptions()
    #expect(base.rendering(as: nil, markdown: "a.qmd") { _ in "x" } == base)
    let options = base.rendering(as: FileFlavor(), markdown: "a.qmd") { $0 == "a.qmd" ? "text" : nil }
    #expect(options.flavor == "files" && options.renderChunks == ["files.chunk.js"] && options.files == ["a.qmd": "text"])
    // everything else is the caller's settings
    var changed = options
    changed.flavor = .markdown; changed.renderChunks = []; changed.files = [:]
    #expect(changed == base)
}

@Test @MainActor func flavorMembersHaveInertDefaults() {
    let flavor = StubFlavor()
    #expect(flavor.editorDecorations(visibleLines: ["# x"], firstLine: 0).isEmpty)
    #expect(flavor.auxiliaryFiles(for: "x", readFile: { _ in "y" }).isEmpty)
    #expect(flavor.badge == nil)
    #expect(NoopExtension.disabledHint == nil)
}

@Test @MainActor func extensionIsFoundByItsSettingKey() {
    let (registry, _) = makeRegistry(freshDefaults())
    #expect(registry.ext(forSettingKey: "extension.off.enabled").map { type(of: $0).id } == "off")
    #expect(registry.ext(forSettingKey: "extension.nope.enabled") == nil)
}

@Test @MainActor func settingsAreNamespacedPerExtension() {
    let defaults = freshDefaults()
    let store = ExtensionSettingsStore(defaults: defaults, extension: "quarto")
    #expect(store.bool("liveRender") == nil)
    store.set(true, for: "liveRender")
    #expect(defaults.bool(forKey: "extension.quarto.liveRender"))
}
