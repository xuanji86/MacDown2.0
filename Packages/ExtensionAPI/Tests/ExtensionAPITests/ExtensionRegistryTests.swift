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
        var toolEnvironment: any ToolEnvironment { provider.toolEnvironment }
        init(id: ExtensionID, provider: FakeProvider) {
            self.id = id
            self.provider = provider
            settings = ExtensionSettingsStore(defaults: provider.defaults, extension: id)
        }
        func register(flavor: any DocumentFlavor) { provider.flavors[id, default: []].append(flavor.id) }
    }
    let defaults: UserDefaults
    let spawner = CountingSpawner()
    lazy var toolEnvironment = LoginShellEnvironment(spawner: spawner, processEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin"])
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

// MARK: PLAN 4.16 / 6.1: the login-shell environment is lazy, and only extensions can ask for it

/// Keeps its host, like an extension that later (on a user action) looks for its tool.
@MainActor private class ToolUsingExtension: MacDown2Extension {
    class var id: ExtensionID { "tool-on" }
    static let displayName: LocalizedStringResource = "Tools"
    static let summary: LocalizedStringResource = "Test extension that needs external tools"
    class var enabledByDefault: Bool { true }
    var host: (any ExtensionHost)?
    required init() {}
    func activate(host: any ExtensionHost) async { self.host = host }  // must not touch toolEnvironment
    func deactivate() async { host = nil }
    /// What a feature does when the user first uses it.
    func findTool() async -> String? { await host?.toolEnvironment.which("sh") }
}

@MainActor private final class ToolUsingOff: ToolUsingExtension {
    override class var id: ExtensionID { "tool-off" }
    override class var enabledByDefault: Bool { false }
}

@Test @MainActor func zeroSpawnsUntilAnEnabledExtensionUsesATool() async throws {
    let defaults = freshDefaults()
    let provider = FakeProvider(defaults: defaults)
    provider.spawner.script(.output(Data("PATH=/bin:/usr/bin\0".utf8)))
    let registry = ExtensionRegistry([ToolUsingExtension.self, ToolUsingOff.self], defaults: defaults, provider: provider)

    // Creating the registry (every `init`) and starting it (every enabled `activate`) reads no environment.
    await registry.start()
    #expect(registry.active == ["tool-on"])
    #expect(provider.spawner.spawns == 0)
    #expect(await provider.toolEnvironment.state() == .notNeeded)

    // Switching things on and off does not either.
    await registry.setEnabled(true, for: "tool-off")
    await registry.setEnabled(false, for: "tool-off")
    await registry.setEnabled(false, for: "tool-on")
    await registry.setEnabled(true, for: "tool-on")
    #expect(provider.spawner.spawns == 0)

    // Only a feature actually using a tool does, once, however often it asks.
    let ext = try #require(registry.extensions.first { type(of: $0).id == "tool-on" } as? ToolUsingExtension)
    #expect(await ext.findTool() == "/bin/sh")
    #expect(await ext.findTool() == "/bin/sh")
    #expect(provider.spawner.spawns == 1)
}

@Test @MainActor func everyExtensionOffMeansTheShellIsNeverRead() async {
    let defaults = freshDefaults()
    defaults.set(false, forKey: ExtensionRegistry.enabledKey("tool-on"))
    let provider = FakeProvider(defaults: defaults)
    let registry = ExtensionRegistry([ToolUsingExtension.self, ToolUsingOff.self], defaults: defaults, provider: provider)
    await registry.start()
    #expect(registry.active.isEmpty)
    #expect(provider.spawner.spawns == 0)
    #expect(await provider.toolEnvironment.state() == .notNeeded)
}
