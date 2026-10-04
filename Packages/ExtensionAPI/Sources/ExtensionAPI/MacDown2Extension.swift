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
    /// Shown once on a document this extension would handle while it is switched off (PLAN 4.6), e.g.
    /// "启用 Quarto 扩展以获得 callout/交叉引用预览". nil = say nothing.
    static var disabledHint: LocalizedStringResource? { get }
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
    public static var disabledHint: LocalizedStringResource? { nil }
}

/// What an extension may register. The app gives each extension its own scoped host.
@MainActor
public protocol ExtensionHost: AnyObject {
    func register(flavor: any DocumentFlavor)
    /// Where external tools (quarto, qmd, python, R) are found and which environment they run in (PLAN 4.16). Lazy: the
    /// login shell is read on the first `snapshot()`, never by obtaining the host or by `init`/`activate`; read this only
    /// when a feature is actually used.
    var toolEnvironment: any ToolEnvironment { get }
    var settings: ExtensionSettingsStore { get }
}

/// A document flavor contributed by an extension. `id` and `renderChunks` must match `flavors.json`.
public protocol DocumentFlavor: Sendable {
    var id: FlavorID { get }
    func matches(contentType: UTType) -> Bool
    var renderChunks: [String] { get }
    var previewStylesheets: [String] { get }
    /// Regex-level overlay for the editor (PLAN 4.3.3): styles to add on top of the Markdown highlighting for
    /// `visibleLines` (consecutive whole lines; `firstLine` is the 0-based index of the first one). Must be cheap and
    /// stateless: it is called for every chunk the editor styles.
    func editorDecorations(visibleLines: [Substring], firstLine: Int) -> [DecorationSpan]
    /// Files the renderer may read for `markdown` (found by scanning it), as `RenderOptions.files`. `readFile` returns the
    /// text of a path relative to the document folder, nil when it cannot or may not be read; the flavor decides which
    /// paths to ask for and when to stop.
    func auxiliaryFiles(for markdown: String, readFile: (String) -> String?) -> [String: String]
    /// A label for the status bar and the preview ("Quarto · 近似预览") when the flavor is an approximation; nil for none.
    var badge: FlavorBadge? { get }
}

extension DocumentFlavor {
    public func editorDecorations(visibleLines: [Substring], firstLine: Int) -> [DecorationSpan] { [] }
    public func auxiliaryFiles(for markdown: String, readFile: (String) -> String?) -> [String: String] { [:] }
    public var badge: FlavorBadge? { nil }
}

/// One styled stretch of a document line. `token` is the raw value of an editor `TokenKind` (themes style them by name;
/// a name the editor does not know is ignored).
public struct DecorationSpan: Sendable, Equatable {
    public var line: Int
    /// UTF-16 columns within the line.
    public var columns: Range<Int>
    public var token: String

    public init(line: Int, columns: Range<Int>, token: String) {
        self.line = line
        self.columns = columns
        self.token = token
    }
}

public struct FlavorBadge: Sendable, Equatable {
    public var title: String
    /// Tooltip.
    public var help: String

    public init(title: String, help: String) {
        self.title = title
        self.help = help
    }
}

extension RenderOptions {
    /// These options for a document of `flavor` (nil = plain Markdown): flavor id, chunks and the files the flavor asks
    /// for. Plain Markdown leaves everything as it is.
    public func rendering(as flavor: (any DocumentFlavor)?, markdown: String, readFile: (String) -> String?) -> RenderOptions {
        guard let flavor else { return self }
        var options = self
        options.flavor = flavor.id
        options.renderChunks = flavor.renderChunks
        options.files = flavor.auxiliaryFiles(for: markdown, readFile: readFile)
        return options
    }
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
