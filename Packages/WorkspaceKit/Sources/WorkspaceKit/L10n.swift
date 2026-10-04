import Foundation

/// The words WorkspaceKit puts in front of the user: sidebar headings and empty states, folder counts, search errors.
/// They come from this module's `Localizable.strings` (`Resources/en.lproj`, `Resources/zh-Hans.lproj`), so they follow the
/// app's language. Plain `.strings` files, not a String Catalog: `swift test` under the Command Line Tools cannot compile
/// catalogs. `Scripts/check-localization.py` keeps both languages complete.
///
/// Internal on purpose: the tests compare against these, not against one language's text.
enum L10n {
    static var favorites: String { String(localized: "Favorites", bundle: .module) }
    static var currentLocation: String { String(localized: "Current Location", bundle: .module) }
    static var recents: String { String(localized: "Recents", bundle: .module) }
    static var dragFoldersHere: String { String(localized: "Drag a folder here, or right-click and choose “Add to Favorites”", bundle: .module) }
    static var noMatches: String { String(localized: "No matches", bundle: .module) }
    static var folderIsEmpty: String { String(localized: "There are no files to show in this folder", bundle: .module) }
    static var noDocumentOpen: String {
        String(localized: "No document is open yet. Open or create one and its folder shows up here; you can also drag a folder in", bundle: .module)
    }
    static var noRecents: String { String(localized: "No files opened recently", bundle: .module) }

    static func folders(_ count: Int) -> String { String(localized: "\(count) folders", bundle: .module) }

    static var invalidRegex: String { String(localized: "Invalid regular expression", bundle: .module) }
    static func truncatedHits(_ count: Int) -> String { String(localized: "Only the first \(count) matches are shown; narrow the search", bundle: .module) }
    static func truncatedFiles(_ count: Int) -> String { String(localized: "Only the first \(count) files were searched; narrow the search", bundle: .module) }
}
