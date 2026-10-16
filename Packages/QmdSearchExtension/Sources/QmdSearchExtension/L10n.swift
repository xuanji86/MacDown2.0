import Foundation

/// The words the qmd extension puts in front of the user. Looked up in this module's `Localizable.strings`
/// (`Resources/en.lproj`, `Resources/zh-Hans.lproj`; plain `.strings` files, because `swift test` under the Command Line Tools cannot
/// compile String Catalogs). Internal: the tests compare against these, not against one language's text.
enum L10n {
    static func resource(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
    }

    // Search panel notes (why the built-in search answered).
    static var notInstalled: String { String(localized: "qmd is not installed; the built-in search is used. Settings ▸ Extensions ▸ qmd Search says how to install it.", bundle: .module) }
    static func notExecutable(_ path: String) -> String { String(localized: "“\(path)” is not an executable qmd; the built-in search is used.", bundle: .module) }
    static func tooOld(path: String, version: String) -> String { String(localized: "qmd \(version) at \(path) is older than 2.8; the built-in search is used.", bundle: .module) }
    static func noteFailed(_ message: String) -> String { String(localized: "qmd failed (\(message)); the built-in search is used.", bundle: .module) }
    static func unknownVersion(_ text: String) -> String { String(localized: "qmd printed no version (“\(text)”)", bundle: .module) }

    static func note(for tool: QmdTool) -> String {
        switch tool {
        case .found: ""
        case .notFound(let manual): manual.map(notExecutable) ?? notInstalled
        case .unsupported(let path, let version): tooOld(path: path, version: version)
        case .broken(_, let message): noteFailed(message)
        }
    }

    static func semanticFailed(_ message: String) -> String { String(localized: "Semantic search failed: \(message)", bundle: .module) }
    static func timedOut(_ seconds: Int64) -> String { String(localized: "qmd did not answer within \(seconds) s", bundle: .module) }
    static var badOutput: String { String(localized: "qmd’s answer could not be read", bundle: .module) }
    static func exitStatus(_ status: Int32) -> String { String(localized: "qmd exited with status \(status)", bundle: .module) }

    // Consent sheet.
    static func consentTitle(folder: String, collection: String) -> String {
        String(localized: "Register “\(folder)” as qmd collection “\(collection)”?", bundle: .module)
    }
    static func consentBody(indexPath: String) -> String {
        String(localized: "qmd will write the contents of these files to its local index \(indexPath), which your other qmd collections share. MacDown2.0 sets the collection to stay out of your default qmd searches in Terminal.", bundle: .module)
    }
    static var register: String { String(localized: "Register", bundle: .module) }
    static var useBuiltin: String { String(localized: "Use Built-in Search", bundle: .module) }

    // Sidebar and settings.
    static var disableIndex: String { String(localized: "Disable qmd Index", bundle: .module) }
    static var looking: String { String(localized: "Looking for qmd…", bundle: .module) }
    static var embedDone: String { String(localized: "Embeddings are up to date", bundle: .module) }
    static var nothingToEmbed: String { String(localized: "No folder uses qmd yet: open the search panel in a folder first", bundle: .module) }
}
