import ExtensionAPI
import Foundation
import MarkdownCore
import Testing
import UniformTypeIdentifiers
import WebAssets
@testable import QuartoExtension

// PLAN 6.1 "extension on/off": every Quarto behaviour is tested enabled and disabled. Disabled means: `activate` never ran
// (the host was never even asked for), no flavor exists, the chunk is never loaded, `.qmd` is plain Markdown.

let qmdType = UTType(importedAs: "org.quarto.qmd", conformingTo: .plainText)

private let sample = """
---
title: "Sample"
---

::: {.callout-note}
## Heads up

A note, see @fig-plot.
:::

```{python}
#| label: fig-plot
print(1)
```
"""

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var chunks: [String] { lock.withLock { names } }
    func note(_ name: String) { lock.withLock { names.append(name) } }
}

@MainActor private final class CountingHost: ExtensionHost {
    let provider: CountingProvider
    let settings: ExtensionSettingsStore
    init(provider: CountingProvider, id: ExtensionID) {
        self.provider = provider
        settings = ExtensionSettingsStore(defaults: provider.defaults, extension: id)
    }
    func register(flavor: any DocumentFlavor) { provider.registered.append(flavor) }
}

@MainActor private final class CountingProvider: ExtensionHostProvider {
    let defaults: UserDefaults
    var hostRequests = 0
    var revocations = 0
    var registered: [any DocumentFlavor] = []
    init(defaults: UserDefaults) { self.defaults = defaults }
    func host(for id: ExtensionID) -> any ExtensionHost {
        hostRequests += 1
        return CountingHost(provider: self, id: id)
    }
    func revokeRegistrations(of id: ExtensionID) {
        revocations += 1
        registered.removeAll()
    }
}

@MainActor private func freshDefaults(quartoEnabled: Bool? = nil) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    if let quartoEnabled { defaults.set(quartoEnabled, forKey: ExtensionRegistry.enabledKey("quarto")) }
    return defaults
}

/// Renders `sample` the way the app does for a .qmd: options from whatever flavor the registry has registered.
@MainActor private func render(provider: CountingProvider, counter: Counter) async throws -> String {
    let flavor = provider.registered.first { $0.matches(contentType: qmdType) }
    let options = RenderOptions().rendering(as: flavor, markdown: sample) { _ in nil }
    let renderer = try JSCRenderer(resolveChunk: { counter.note($0); return WebAssets.url($0) })
    return try await renderer.render(sample, options: options).html
}

@Test @MainActor func flavorAndManifestSayTheSameThing() throws {
    let flavor = QuartoFlavor()
    let entry = try #require(FlavorManifest.bundled().entries[flavor.id])
    #expect(entry.chunks == flavor.renderChunks)
    #expect(entry.stylesheets == flavor.previewStylesheets)
    #expect(entry.utTypes == [QuartoFlavor.typeIdentifier])
    #expect(entry.settingKey == ExtensionRegistry.enabledKey(QuartoExtension.id))
    for name in entry.chunks + entry.stylesheets { #expect(WebAssets.url(name) != nil, "\(name) is not in WebAssets") }
    #expect(flavor.matches(contentType: qmdType))
    #expect(!flavor.matches(contentType: UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)))
    #expect(!flavor.matches(contentType: .plainText))
}

@Test @MainActor func extensionMetadata() {
    #expect(QuartoExtension.id == "quarto")
    #expect(QuartoExtension.enabledByDefault)
    #expect(QuartoExtension.disabledHint != nil)
    #expect(QuartoExtension().settingsPane() != nil)
    #expect(QuartoFlavor().badge == FlavorBadge(title: "Quarto · 近似预览", help: "未执行代码、未应用项目配置"))
}

@Test @MainActor func enabledByDefaultActivatesAndOnlyRegistersAFlavor() async throws {
    let defaults = freshDefaults()
    let provider = CountingProvider(defaults: defaults)
    let registry = ExtensionRegistry([QuartoExtension.self], defaults: defaults, provider: provider)
    await registry.start()
    #expect(registry.active == ["quarto"])
    #expect(provider.hostRequests == 1)
    #expect(provider.registered.map(\.id) == ["quarto"])  // the only thing activate does (no tool probing, no environment)
    #expect(defaults.bool(forKey: "extension.quarto.enabled"))
}

@Test @MainActor func enabled_qmdRendersWithQuartoSyntaxAndLoadsTheChunkOnce() async throws {
    let provider = CountingProvider(defaults: freshDefaults())
    await ExtensionRegistry([QuartoExtension.self], defaults: provider.defaults, provider: provider).start()
    let counter = Counter()
    let html = try await render(provider: provider, counter: counter)
    #expect(html.contains(#"class="callout callout-note callout-style-default""#))
    #expect(html.contains(##"<a class="quarto-xref" href="#fig-plot">Figure ?</a>"##))
    #expect(html.contains(#"<div class="quarto-cell""#) && html.contains(#"id="fig-plot""#))
    #expect(html.contains(#"<h1>Sample</h1>"#))
    #expect(counter.chunks == ["quarto.chunk.js"])
}

@Test @MainActor func disabled_nothingActivatesNoFlavorNoChunkAndQmdIsPlainMarkdown() async throws {
    let defaults = freshDefaults(quartoEnabled: false)
    let provider = CountingProvider(defaults: defaults)
    let registry = ExtensionRegistry([QuartoExtension.self], defaults: defaults, provider: provider)
    await registry.start()
    #expect(registry.active.isEmpty)
    #expect(provider.hostRequests == 0)  // activate never ran
    #expect(provider.registered.isEmpty)

    let counter = Counter()
    let html = try await render(provider: provider, counter: counter)
    #expect(counter.chunks.isEmpty)  // the chunk is never even looked up
    #expect(!html.contains(#"class="callout"#) && !html.contains("quarto-cell") && !html.contains("quarto-xref"))
    #expect(html.contains("{.callout-note}"))  // the fence line shows as text, like any non-Quarto Markdown

    // And the quarto flavor does not exist in a context that never loaded the chunk.
    var options = RenderOptions()
    options.flavor = "quarto"
    await #expect(throws: RenderError.self) { try await JSCRenderer().render(sample, options: options) }
}

@Test @MainActor func quickLookPathFollowsTheSameSwitch() throws {
    let manifest = try FlavorManifest.bundled()
    let on = manifest.resolve(utType: QuartoFlavor.typeIdentifier) { $0 == "extension.quarto.enabled" }
    #expect(on.flavor == "quarto" && on.chunks == ["quarto.chunk.js"])
    let off = manifest.resolve(utType: QuartoFlavor.typeIdentifier) { _ in false }
    #expect(off.flavor == .markdown && off.chunks.isEmpty)
}

@Test @MainActor func switchingOffWhileRunningRevokesAndSwitchingOnRegistersAgain() async throws {
    let defaults = freshDefaults()
    let provider = CountingProvider(defaults: defaults)
    let registry = ExtensionRegistry([QuartoExtension.self], defaults: defaults, provider: provider)
    await registry.start()
    #expect(provider.registered.count == 1)

    await registry.setEnabled(false, for: "quarto")
    #expect(provider.revocations == 1 && provider.registered.isEmpty)
    let counter = Counter()
    #expect(!(try await render(provider: provider, counter: counter)).contains(#"class="callout"#))
    #expect(counter.chunks.isEmpty)

    await registry.setEnabled(true, for: "quarto")
    #expect(provider.hostRequests == 2 && provider.registered.count == 1)
    #expect(try await render(provider: provider, counter: counter).contains(#"class="callout"#))
    #expect(counter.chunks == ["quarto.chunk.js"])
}
