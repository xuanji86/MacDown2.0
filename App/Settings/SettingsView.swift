import AppKit
import EditorKit
import ExtensionAPI
import MarkdownCore
import SwiftUI
import WebAssets
import WorkspaceKit

/// The ⌘, window (PLAN §4.8). Only settings that something already honours are shown; the rest of each page arrives
/// with its feature.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPage() }
            Tab("Editor", systemImage: "square.and.pencil") { EditorPage() }
            Tab("Markdown", systemImage: "text.badge.checkmark") { MarkdownPage() }
            Tab("Rendering", systemImage: "eye") { RenderingPage() }
            Tab("Export", systemImage: "square.and.arrow.up") { ExportPage() }
            Tab("Extensions", systemImage: "puzzlepiece.extension") { ExtensionsPage() }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdatesPage() }
        }
        .scenePadding()
        .frame(width: 560, height: 520)
    }
}

// MARK: General

private struct GeneralPage: View {
    var body: some View {
        Form {
            LanguageSection()
            IconStyleSection()
            ToolEnvironmentSection()
            Section { Text("More general settings will arrive with later features.").foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

/// "Language / 语言": the app's own override of the system language (`AppLanguage`), applied at the next launch.
private struct LanguageSection: View {
    @State private var language = AppLanguage.current
    @State private var asksToRelaunch = false

    var body: some View {
        Section {
            Picker(selection: $language) {
                ForEach(AppLanguage.allCases) { $0.title.tag($0) }
            } label: {
                Text(verbatim: "Language / 语言")  // l10n: native-name (the one label that must be findable in either language)
            }
            .onChange(of: language) { _, new in
                new.save()
                asksToRelaunch = true
            }
            .alert("Relaunch to change the language?", isPresented: $asksToRelaunch) {
                Button("Relaunch Now") { AppRelauncher.relaunch() }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Menus and windows switch to the new language after MacDown2 relaunches.")
            }
        } footer: {
            Text("Follow System uses the language set in System Settings. The choice takes effect when MacDown2 is relaunched.")
        }
    }
}

/// "App Icon": Follow System (the bundle's adaptive icon) or one of its four appearances. `IconStyle.start()` applies the choice.
private struct IconStyleSection: View {
    @AppStorage(IconStyle.key) private var raw = IconStyle.system.rawValue

    var body: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(IconStyle.allCases) { style in
                    let selected = (IconStyle(rawValue: raw) ?? .system) == style
                    Button { raw = style.rawValue } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: style.thumbnail).resizable().frame(width: 56, height: 56)
                            Text(style.title).font(.caption)
                        }
                        .padding(6)
                        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                        .overlay { if selected { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("App Icon: \(style.title)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("App Icon")
        } footer: {
            Text("The Dock icon while the app is running; the icon in Finder follows the system appearance")
        }
    }
}

/// PLAN 4.16: where the environment for external tools (quarto, qmd, python, R) came from. Looking at this row never reads
/// the login shell (`state()` only reports); the button is an explicit request and does.
private struct ToolEnvironmentSection: View {
    @State private var state: ToolEnvironmentState = .notNeeded

    var body: some View {
        Section {
            LabeledContent("Status") { Text(summary).multilineTextAlignment(.trailing) }
            if case .ready(let snapshot) = state, case .fallback = snapshot.source {
                Text("Using this app’s own environment, with /opt/homebrew/bin, /usr/local/bin and ~/.local/bin added.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Re-read") {
                state = .loading
                Task {
                    await AppExtensions.loginShell.reread()
                    state = await AppExtensions.loginShell.state()
                }
            }
            .disabled(state == .loading)
        } header: {
            Text("External Tool Environment")
        } footer: {
            Text("Extensions such as Quarto and qmd start external programs in your login shell’s environment (so they can find Homebrew’s PATH). It is read once, only when an enabled extension actually needs a tool; after you change your shell configuration you can re-read it here.")
        }
        .task { state = await AppExtensions.loginShell.state() }
    }

    private var summary: String {
        switch state {
        case .notNeeded: String(localized: "Not needed yet")
        case .loading: String(localized: "Loading…")
        case .ready(let snapshot):
            switch snapshot.source {
            case .loginShell(let path): String(localized: "\(path) · \(String(format: "%.2f", snapshot.seconds)) s · PATH has \(snapshot.path.count) entries")
            case .fallback(let reason): String(localized: "Could not read the environment (\(reason)) · PATH has \(snapshot.path.count) entries")
            }
        }
    }
}

// MARK: Extensions

/// One row per built-in extension (PLAN 4.8 / 4.17): name, one line, a switch; an enabled extension's own settings fold out
/// below. A switched-off extension shows no settings and none of its code runs (`settingsPane()` is not even called).
private struct ExtensionsPage: View {
    var body: some View {
        Form {
            ForEach(Array(AppExtensions.registry.extensions.enumerated()), id: \.offset) { _, ext in
                ExtensionRow(ext: ext)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionRow: View {
    let ext: any MacDown2Extension
    // The same key the registry and Quick Look read; `setEnabled` below does the activating.
    @AppStorage private var enabled: Bool
    @State private var showsSettings = false

    init(ext: any MacDown2Extension) {
        self.ext = ext
        let kind = type(of: ext)
        _enabled = AppStorage(wrappedValue: kind.enabledByDefault, ExtensionRegistry.enabledKey(kind.id), store: AppExtensions.preferences)
    }

    var body: some View {
        let kind = type(of: ext)
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.headline)
                    Text(kind.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            .onChange(of: enabled) { _, on in
                Task { await AppExtensions.registry.setEnabled(on, for: kind.id) }
            }
            if enabled, let pane = ext.settingsPane() {
                DisclosureGroup("Settings", isExpanded: $showsSettings) { pane }
            }
        }
    }
}

// MARK: Editor

private struct EditorPage: View {
    @AppStorage(AppearanceKey.editorTheme) private var theme = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var themeFollows = false
    @AppStorage(ScrollSyncPreferences.syncKey) private var syncScrolling = true
    @AppStorage(ScrollSyncPreferences.followCaretKey) private var previewFollowsCaret = false
    @AppStorage(SplitMode.settingKey) private var newWindowLayout = SplitMode.both
    @AppStorage(WindowChromeKey.statusBar) private var showsStatusBar = false
    @AppStorage(WindowChromeKey.divider) private var showsDivider = false
    @AppStorage(ToolbarStyle.key) private var toolbarStyle = ToolbarStyle.default
    private var editor = EditorSettings()

    // lazy: scanned once per launch on first use (a few hundred families, ~ms); cache invalidation on font install not handled.
    private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter {
        NSFont(name: $0, size: 13)?.isFixedPitch == true
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Editor Theme", selection: $theme) {
                    ForEach(ThemeLibrary.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                Toggle("Follow System", isOn: $themeFollows)
                Picker("Font", selection: editor.$fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: editor.$fontSize, in: 8...72, step: 1) { Text("Font size: \(Int(editor.fontSize)) pt") }
                Stepper(value: editor.$lineSpacing, in: Double(EditorViewSettings.lineSpacingRange.lowerBound)...Double(EditorViewSettings.lineSpacingRange.upperBound), step: 1) {
                    Text("Extra line spacing: \(Int(editor.lineSpacing)) pt")
                }
                Toggle("Show Line Numbers", isOn: editor.$lineNumbers)
                Toggle("Show invisible characters (spaces, tabs, line breaks)", isOn: editor.$showInvisibles)
                Toggle("Editor on the right (preview on the left)", isOn: editor.$editorOnRight)
                Toggle("Limit the editor width and center it", isOn: editor.$limitWidth)
                Stepper(value: editor.$maxWidth, in: Double(EditorViewSettings.maxWidthRange.lowerBound)...Double(EditorViewSettings.maxWidthRange.upperBound), step: 20) {
                    Text("Maximum width: \(Int(editor.maxWidth)) px")
                }
                .disabled(!editor.limitWidth)
            }
            Section("Layout") {
                Picker("Startup Layout", selection: $newWindowLayout) {
                    Text("Two Panes").tag(SplitMode.both)
                    Text("Editor Only").tag(SplitMode.editorOnly)
                    Text("Preview Only").tag(SplitMode.previewOnly)
                }
                .pickerStyle(.segmented)
                Text("New windows start with this layout. Reopened windows and folders whose layout you changed keep their own last layout; --editor-only, --preview-only and --both on the command line take priority.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Picker("Toolbar Style", selection: $toolbarStyle) {
                    ForEach(ToolbarStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("Minimal: one compact title-bar row with the file name on the tab. Classic: the original two rows, a centred title and a toolbar below it. Changes apply at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show a divider between the editor and the preview", isOn: $showsDivider)
                Toggle("Show the status bar (line and column, word count, encoding)", isOn: $showsStatusBar)
                Text("Both are hidden by default, as in the original MacDown. With the status bar hidden, the encoding can still be changed in File ▸ Encoding; with the divider hidden you can still drag the boundary between the two panes to resize them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Typing") {
                Toggle("Auto-pair brackets and quotes", isOn: editor.$autoPair)
                Toggle("Continue lists and quotes on Return", isOn: editor.$continueLists)
                Toggle("Auto-increment ordered lists", isOn: editor.$autoNumberLists).disabled(!editor.continueLists)
                Toggle("Insert spaces for Tab", isOn: editor.$tabInsertsSpaces)
                Stepper(value: editor.$tabWidth, in: 1...8) { Text("Tab width: \(editor.tabWidth)") }
                Picker("Unordered list marker", selection: editor.$listMarker) {
                    ForEach(EditorSettings.listMarkers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("⌘← goes to the first non-blank character of the line first", isOn: editor.$smartHome)
            }
            Section {
                Toggle("Smart quotes (straight quotes become curly)", isOn: editor.$smartQuotes)
                Toggle("Smart dashes (-- becomes —)", isOn: editor.$smartDashes)
                Toggle("Text replacement (the replacement list in System Settings, double space becomes a period)", isOn: editor.$textReplacement)
                Toggle("Spelling correction (the system counts automatic capitalization here too)", isOn: editor.$spellingCorrection)
                Toggle("Smart insert and delete (adds spaces when pasting and cutting)", isOn: editor.$smartInsertDelete)
            } header: {
                Text("System Text Substitutions")
            } footer: {
                Text("These rewrite the characters you type, so they are all off by default when writing Markdown source.")
            }
            Section("Scrolling") {
                Toggle("Scroll the editor and preview together", isOn: $syncScrolling)
                Toggle("Preview follows the caret", isOn: $previewFollowsCaret)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Markdown

private struct MarkdownPage: View {
    @Bindable private var render = RenderSettings.shared

    // Strings, not LocalizedStringKeys: several hold markup (~~x~~, _x_) that a LocalizedStringKey would render as Markdown.
    private static let syntax: [(MarkdownExtension, String)] = [
        (.tables, String(localized: "Tables")), (.autolink, String(localized: "Autolinks")),
        (.strikethrough, String(localized: "Strikethrough ~~x~~")), (.mark, String(localized: "Highlight ==x==")),
        (.sup, String(localized: "Superscript x^2^")), (.sub, String(localized: "Subscript H~2~O")),
        (.underline, String(localized: "Underline _x_")), (.footnotes, String(localized: "Footnotes")),
        (.taskLists, String(localized: "Task Lists")), (.smartPunctuation, String(localized: "Smart punctuation (curly quotes, dashes)")),
        (.toc, String(localized: "[TOC] Table of Contents")), (.cjkEmphasis, String(localized: "CJK-friendly emphasis")),
        (.emoji, String(localized: "Emoji shortcodes :smile:")),
    ]

    var body: some View {
        Form {
            Section("Syntax") {
                ForEach(Self.syntax, id: \.0) { ext, label in Toggle(label, isOn: render.binding(ext)) }
            }
            Section("Front matter") {
                Toggle("Detect leading front matter (YAML ---, TOML +++)", isOn: render.binding(.frontMatter))
                Picker("Show in preview as", selection: $render.preferences.frontMatterDisplay) {
                    Text("Hidden").tag(FrontMatterDisplay.hidden)
                    Text("Table").tag(FrontMatterDisplay.table)
                }
                .disabled(!render.preferences.extensions.contains(.frontMatter))
            }
            Section("HTML and Line Breaks") {
                Toggle("Render raw HTML", isOn: $render.preferences.allowRawHTML)
                Toggle("Hard line breaks (Return makes a line break)", isOn: $render.preferences.hardBreaks)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Rendering

private struct RenderingPage: View {
    @AppStorage(AppearanceKey.previewStyle) private var style = AppearanceDefault.previewStyle
    @AppStorage(AppearanceKey.previewStyleFollowsSystem) private var styleFollows = false
    @AppStorage(RemoteContent.blockImagesKey) private var blockRemoteImages = false
    @Bindable private var render = RenderSettings.shared

    var body: some View {
        Form {
            Section("Preview") {
                Picker("Preview Style", selection: $style) {
                    ForEach(PreviewStyles.all) { Text($0.name).tag($0.id) }
                }
                Toggle("Follow System", isOn: $styleFollows)
            }
            Section {
                Toggle("Block remote images", isOn: $blockRemoteImages)
            } header: {
                Text("Remote Content")
            } footer: {
                Text("Off by default: the preview loads the https images in a document from the network. When on, the preview no longer fetches images, and blocked images are not shown. Quick Look never loads remote images.")
            }
            Section("Code") {
                Toggle("Syntax highlighting", isOn: $render.preferences.codeHighlighting)
                Toggle("Show Line Numbers", isOn: $render.preferences.codeLineNumbers)
            }
            Section("Math") {
                Toggle("Render math (KaTeX)", isOn: render.binding(.math))
                Toggle("Inline $…$ counts as math too", isOn: $render.preferences.inlineDollarMath)
                    .disabled(!render.preferences.extensions.contains(.math))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Export

/// Paper, orientation and margins for File > Export > PDF and Print (`PageSetup`, MarkdownCore; `macdown2 render --export pdf`
/// reads the same keys). Page Setup… in the File menu edits these too.
private struct ExportPage: View {
    @AppStorage(PageSetup.Key.paper) private var paper = PageSetup.Paper.standard().rawValue
    @AppStorage(PageSetup.Key.orientation) private var orientation = PageSetup.Orientation.portrait.rawValue
    @AppStorage(PageSetup.Key.top) private var top = PageSetup.defaultMargin
    @AppStorage(PageSetup.Key.right) private var right = PageSetup.defaultMargin
    @AppStorage(PageSetup.Key.bottom) private var bottom = PageSetup.defaultMargin
    @AppStorage(PageSetup.Key.left) private var left = PageSetup.defaultMargin

    private static let usesInches = Locale.current.measurementSystem == .us

    var body: some View {
        Form {
            Section("Paper") {
                Picker("Paper Size", selection: $paper) {
                    ForEach(PageSetup.Paper.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Orientation", selection: $orientation) {
                    Text("Portrait").tag(PageSetup.Orientation.portrait.rawValue)
                    Text("Landscape").tag(PageSetup.Orientation.landscape.rawValue)
                }
            }
            Section("Margins (\(Self.usesInches ? String(localized: "inches") : String(localized: "millimeters")))") {
                MarginField(label: "Top", points: $top, inches: Self.usesInches)
                MarginField(label: "Bottom", points: $bottom, inches: Self.usesInches)
                MarginField(label: "Left", points: $left, inches: Self.usesInches)
                MarginField(label: "Right", points: $right, inches: Self.usesInches)
            }
            Section {
                Button("Restore Defaults") {
                    let standard = PageSetup()
                    paper = standard.paper.rawValue
                    orientation = standard.orientation.rawValue
                    (top, right, bottom, left) = (standard.top, standard.right, standard.bottom, standard.left)
                }
                Text("Used for Export ▸ PDF and Print, and for macdown2 render --export pdf. A line containing only \\newpage or <div style=\"page-break-after: always\"></div> (Format ▸ Insert Page Break) starts a new page; the preview shows it as a dashed line.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A margin kept in points, edited in the user's unit.
private struct MarginField: View {
    let label: LocalizedStringKey
    @Binding var points: Double
    let inches: Bool

    private var unit: Binding<Double> {
        let perPoint = inches ? 1.0 / 72 : 25.4 / 72
        return Binding(
            get: { points * perPoint },
            set: { points = min(max($0 / perPoint, PageSetup.marginRange.lowerBound), PageSetup.marginRange.upperBound) }
        )
    }

    var body: some View {
        TextField(label, value: unit, format: .number.precision(.fractionLength(0...2)))
            .multilineTextAlignment(.trailing)
    }
}

// MARK: Updates

private struct UpdatesPage: View {
    @Bindable private var updater = UpdaterController.shared

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Picker("Check Frequency", selection: $updater.checkInterval) {
                    ForEach(UpdaterController.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                .disabled(!updater.automaticallyChecks)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .disabled(!updater.isConfigured)
            if !updater.isConfigured {
                Section { Text("This build has no update signing public key (SUPublicEDKey), so update checks are turned off.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
