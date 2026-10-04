import Foundation

/// The words the Quarto extension puts in front of the user. Looked up in this module's `Localizable.strings`
/// (`Resources/en.lproj`, `Resources/zh-Hans.lproj`; plain `.strings` files, because `swift test` under the Command Line Tools cannot
/// compile String Catalogs). Internal: the tests compare against these, not against one language's text.
enum L10n {
    /// A resource that looks its text up in this module, for the `LocalizedStringResource` the extension protocol asks for.
    static func resource(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
    }

    static var badgeTitle: String { String(localized: "Quarto · Approximate Preview", bundle: .module) }
    static var badgeHelp: String { String(localized: "Code was not run and the project configuration was not applied", bundle: .module) }
}
