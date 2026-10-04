import Foundation

/// The built-in editor themes (JSON files in `Resources/Themes`, written for this app) and the rule that picks one.
/// User themes (`~/Library/Application Support/MacDown2/Themes/`) are M2: they would join `all` and nothing else changes.
public enum ThemeLibrary {
    /// Display order. A test checks this against the files in `Resources/Themes`.
    static let builtInFiles = ["macdown-classic", "default-dark", "default-light", "solarized-dark", "solarized-light", "github-dark", "github-light"]

    public static let all: [EditorTheme] = builtInFiles.map { file in
        do {
            guard let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Resources/Themes") else {
                fatalError("built-in theme \(file).json is missing from the EditorKit bundle")
            }
            return try EditorTheme(json: Data(contentsOf: url))
        } catch {
            fatalError("built-in theme \(file).json is invalid: \(error)")  // shipped in the binary: a build problem, caught by the tests
        }
    }

    public static func theme(named name: String) -> EditorTheme? { all.first { $0.name == name } }

    static func builtIn(named name: String) -> EditorTheme {
        guard let theme = theme(named: name) else { fatalError("no built-in theme named \(name)") }
        return theme
    }

    /// The theme to show for a saved choice. A fixed choice (`followSystem` false) is that theme whatever the system looks like
    /// (unknown name, e.g. a deleted user theme: the default). Following the system swaps in the chosen theme's counterpart
    /// when the chosen one is for the other appearance; a theme without a counterpart (or `auto`) is used as it is.
    public static func resolve(name: String, followSystem: Bool, systemIsDark: Bool, among themes: [EditorTheme] = all) -> EditorTheme {
        let chosen = themes.first { $0.name == name } ?? .default
        guard followSystem, chosen.appearance != .auto,
              (chosen.appearance == .dark) != systemIsDark,
              let other = themes.first(where: { $0.name == chosen.counterpart })
        else { return chosen }
        return other
    }
}
