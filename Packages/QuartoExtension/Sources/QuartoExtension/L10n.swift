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

    // Real render (PLAN 4.6.2)
    static var commandTitle: String { String(localized: "Render with Quarto", bundle: .module) }
    static var confirmTitle: String { String(localized: "Run this document’s code with Quarto?", bundle: .module) }
    static var confirmMessage: String {
        String(localized: "Quarto on this Mac will run the code cells in this document, including ```{python} blocks and inline `{python} expr` and `r expr` code. Only do this for documents you trust.", bundle: .module)
    }
    static func confirmProjectMessage(_ file: String, _ project: String) -> String {
        String(localized: "“\(file)” is part of the Quarto project in \(project). Quarto on this Mac will render the whole project: the code cells of every document in it, and the project’s filters and scripts, may run. Only do this for projects you trust.", bundle: .module)
    }
    static var confirmButton: String { String(localized: "Render", bundle: .module) }
    static var quartoNotFound: String {
        String(localized: "Quarto was not found. Install Quarto 1.4 or later from quarto.org, or set its path in Settings ▸ Extensions ▸ Quarto.", bundle: .module)
    }
    static func notExecutable(_ path: String) -> String { String(localized: "\(path) is not an executable file.", bundle: .module) }
    static func versionFailed(_ path: String, _ reason: String) -> String { String(localized: "“\(path) --version” failed (\(reason)).", bundle: .module) }
    static func tooOld(_ version: String, _ path: String) -> String {
        String(localized: "Quarto \(version) at \(path) is too old: real rendering needs 1.4 or later.", bundle: .module)
    }
    static func exited(_ code: Int) -> String { String(localized: "Quarto exited (code \(code))", bundle: .module) }
    static var renderFailed: String { String(localized: "Quarto could not render the document; see the log.", bundle: .module) }
    static var startTimedOut: String { String(localized: "Quarto did not start a preview within 30 seconds.", bundle: .module) }
    static func launchFailed(_ reason: String) -> String { String(localized: "Could not start Quarto (\(reason)).", bundle: .module) }
    static var emptyLog: String { String(localized: "Quarto has not written anything yet.", bundle: .module) }
}
