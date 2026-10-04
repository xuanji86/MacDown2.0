import Foundation

/// The words ExtensionAPI puts in front of the user (just the built-in search provider's badge). Looked up in this module's
/// `Localizable.strings` (`Resources/en.lproj`, `Resources/zh-Hans.lproj`; plain `.strings` files, because `swift test` under the
/// Command Line Tools cannot compile String Catalogs). Internal: the tests compare against these, not against one language's text.
///
/// The tool-environment status strings (`ToolEnvironmentSnapshot.Source.fallback(reason:)`) stay English on purpose: they are
/// diagnostics that quote the shell's and the system's own English error text, shown after a translated heading in Settings.
enum L10n {
    static var builtinBadge: String { String(localized: "Built-in", bundle: .module) }
}
