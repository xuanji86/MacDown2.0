import AppKit
import ExtensionAPI
import Foundation
import Observation
import SwiftUI

/// qmd search (PLAN 4.12): the sidebar's search panel also asks the user's own `qmd` (tobi/qmd, BM25 and optional semantic
/// search over a local index). Off by default. On: `activate` only registers the provider; looking for qmd, asking before a
/// folder goes into qmd's shared index and registering it all wait until the search panel is first opened (`prepare`).
/// Switched off while running: every qmd process is killed, the panel falls back to the built-in search, collections stay.
@MainActor
public final class QmdSearchExtension: MacDown2Extension {
    public static let id: ExtensionID = "qmd-search"
    public static let displayName = L10n.resource("qmd Search")
    public static let summary = L10n.resource("Searches folders with your installed qmd (keyword and optional semantic search) instead of the built-in search.")
    public static let enabledByDefault = false

    private var provider: QmdSearchProvider?
    private var settings: QmdSettings?

    public required init() {}

    public func activate(host: any ExtensionHost) async {
        let settings = QmdSettings(store: host.settings)
        let provider = QmdSearchProvider(dependencies: QmdEngine.Dependencies(
            environment: host.toolEnvironment,
            options: { await settings.options },
            consent: { await QmdConsent.ask($0) },
            decline: { await settings.decline($0) }
        ), semantic: settings.semantic)
        settings.onSemanticChange = { [weak provider] in provider?.setSemantic($0) }
        self.settings = settings
        self.provider = provider
        host.register(searchProvider: provider)
    }

    public func deactivate() async {
        let provider = provider
        self.provider = nil
        settings = nil
        await provider?.shutdown()
    }

    public func settingsPane() -> AnyView? {
        guard let settings, let provider else { return nil }
        return AnyView(QmdSettingsPane(settings: settings, engine: provider.engine))
    }
}

/// The extension's preferences (`extension.qmd-search.*`). Semantic search, reranking and background embedding are off
/// until the user turns them on.
@MainActor @Observable
final class QmdSettings {
    enum Key {
        static let path = "path"
        static let semantic = "semantic"
        static let rerank = "rerank"
        static let autoEmbed = "autoEmbed"
        static let declined = "declinedFolders"
    }

    @ObservationIgnored private let store: ExtensionSettingsStore
    @ObservationIgnored var onSemanticChange: ((Bool) -> Void)?

    var manualPath: String { didSet { store.set(manualPath.isEmpty ? nil : manualPath, for: Key.path) } }
    var semantic: Bool {
        didSet {
            store.set(semantic, for: Key.semantic)
            onSemanticChange?(semantic)
        }
    }
    var rerank: Bool { didSet { store.set(rerank, for: Key.rerank) } }
    var autoEmbed: Bool { didSet { store.set(autoEmbed, for: Key.autoEmbed) } }
    private(set) var declinedFolders: Set<String>

    init(store: ExtensionSettingsStore) {
        self.store = store
        manualPath = store.string(Key.path) ?? ""
        semantic = store.bool(Key.semantic) ?? false
        rerank = store.bool(Key.rerank) ?? false
        autoEmbed = store.bool(Key.autoEmbed) ?? false
        declinedFolders = Set((store.string(Key.declined) ?? "").split(separator: "\n").map(String.init))
    }

    var options: QmdOptions {
        QmdOptions(manualPath: manualPath, semantic: semantic, rerank: rerank, autoEmbed: autoEmbed, declinedFolders: declinedFolders)
    }

    func decline(_ realRoot: String) {
        declinedFolders.insert(realRoot)
        store.set(declinedFolders.sorted().joined(separator: "\n"), for: Key.declined)
    }

    /// "Use qmd for every folder again": forgets the folders that were declined or whose index was disabled.
    func forgetDeclined() {
        declinedFolders = []
        store.set(nil, for: Key.declined)
    }
}

/// The consent sheet (PLAN 4.12): qmd's index is shared with the user's other collections and agents, so a folder goes in
/// only when they agree.
enum QmdConsent {
    @MainActor static func ask(_ request: QmdConsentRequest) async -> QmdConsentAnswer {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return .notAsked }
        let alert = NSAlert()
        alert.messageText = L10n.consentTitle(folder: request.folder.lastPathComponent, collection: request.collection)
        alert.informativeText = L10n.consentBody(indexPath: request.indexPath)
        alert.addButton(withTitle: L10n.register)
        alert.addButton(withTitle: L10n.useBuiltin)
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? .register : .declined
    }
}
