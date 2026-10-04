import AppKit
import EditorKit
import ExtensionAPI
import MarkdownCore
import SwiftUI
import WebAssets

/// The ⌘, window (PLAN §4.8). Only settings that something already honours are shown; the rest of each page arrives
/// with its feature.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { PlaceholderPage("更多通用设置将随后续功能加入。") }
            Tab("Editor", systemImage: "square.and.pencil") { EditorPage() }
            Tab("Markdown", systemImage: "text.badge.checkmark") { MarkdownPage() }
            Tab("Rendering", systemImage: "eye") { RenderingPage() }
            Tab("扩展", systemImage: "puzzlepiece.extension") { ExtensionsPage() }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdatesPage() }
        }
        .scenePadding()
        .frame(width: 560, height: 520)
    }
}

private struct PlaceholderPage: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Form { Text(text).foregroundStyle(.secondary) }.formStyle(.grouped)
    }
}

// MARK: 扩展

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
                DisclosureGroup("设置", isExpanded: $showsSettings) { pane }
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
    private var editor = EditorSettings()

    // lazy: scanned once per launch on first use (a few hundred families, ~ms); cache invalidation on font install not handled.
    private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter {
        NSFont(name: $0, size: 13)?.isFixedPitch == true
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("编辑器主题", selection: $theme) {
                    ForEach(ThemeLibrary.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                Toggle("跟随系统", isOn: $themeFollows)
                Picker("字体", selection: editor.$fontName) {
                    Text("系统等宽").tag("")
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: editor.$fontSize, in: 8...72, step: 1) { Text("字号:\(Int(editor.fontSize)) pt") }
                Stepper(value: editor.$lineSpacing, in: Double(EditorViewSettings.lineSpacingRange.lowerBound)...Double(EditorViewSettings.lineSpacingRange.upperBound), step: 1) {
                    Text("行距:额外 \(Int(editor.lineSpacing)) pt")
                }
                Toggle("显示行号", isOn: editor.$lineNumbers)
                Toggle("显示不可见字符(空格、Tab、换行)", isOn: editor.$showInvisibles)
                Toggle("编辑器在右侧(预览在左)", isOn: editor.$editorOnRight)
                Toggle("限制编辑区宽度并居中", isOn: editor.$limitWidth)
                Stepper(value: editor.$maxWidth, in: Double(EditorViewSettings.maxWidthRange.lowerBound)...Double(EditorViewSettings.maxWidthRange.upperBound), step: 20) {
                    Text("最大宽度:\(Int(editor.maxWidth)) px")
                }
                .disabled(!editor.limitWidth)
            }
            Section("输入") {
                Toggle("自动配对括号和引号", isOn: editor.$autoPair)
                Toggle("回车续写列表和引用", isOn: editor.$continueLists)
                Toggle("有序列表自动递增", isOn: editor.$autoNumberLists).disabled(!editor.continueLists)
                Toggle("Tab 转为空格", isOn: editor.$tabInsertsSpaces)
                Stepper(value: editor.$tabWidth, in: 1...8) { Text("Tab 宽度:\(editor.tabWidth)") }
                Picker("无序列表标记", selection: editor.$listMarker) {
                    ForEach(EditorSettings.listMarkers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("⌘← 先到行首第一个非空白字符", isOn: editor.$smartHome)
            }
            Section {
                Toggle("智能引号(直引号变弯引号)", isOn: editor.$smartQuotes)
                Toggle("智能破折号(-- 变成 —)", isOn: editor.$smartDashes)
                Toggle("文本替换(系统设置里的替换表、双空格变句号)", isOn: editor.$textReplacement)
                Toggle("拼写自动更正(系统把自动大写算在这一项里)", isOn: editor.$spellingCorrection)
                Toggle("智能增删空格(粘贴、剪切时补空格)", isOn: editor.$smartInsertDelete)
            } header: {
                Text("系统智能替换")
            } footer: {
                Text("这些会改写你输入的字符,写 Markdown 源码时默认全部关闭。")
            }
            Section("滚动") {
                Toggle("编辑器与预览同步滚动", isOn: $syncScrolling)
                Toggle("预览跟随光标", isOn: $previewFollowsCaret)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Markdown

private struct MarkdownPage: View {
    @Bindable private var render = RenderSettings.shared

    private static let syntax: [(MarkdownExtension, String)] = [
        (.tables, "表格"), (.autolink, "自动链接"), (.strikethrough, "删除线 ~~x~~"), (.mark, "高亮 ==x=="),
        (.sup, "上标 x^2^"), (.sub, "下标 H~2~O"), (.underline, "下划线 _x_"), (.footnotes, "脚注"),
        (.taskLists, "任务列表"), (.smartPunctuation, "智能标点(弯引号、破折号)"), (.toc, "[TOC] 目录"),
        (.cjkEmphasis, "CJK 友好强调"), (.emoji, "Emoji 短码 :smile:"),
    ]

    var body: some View {
        Form {
            Section("语法") {
                ForEach(Self.syntax, id: \.0) { ext, label in Toggle(label, isOn: render.binding(ext)) }
            }
            Section("Front matter") {
                Toggle("识别开头的 front matter(YAML ---、TOML +++)", isOn: render.binding(.frontMatter))
                Picker("预览中显示为", selection: $render.preferences.frontMatterDisplay) {
                    Text("隐藏").tag(FrontMatterDisplay.hidden)
                    Text("表格").tag(FrontMatterDisplay.table)
                }
                .disabled(!render.preferences.extensions.contains(.frontMatter))
            }
            Section("HTML 与换行") {
                Toggle("渲染原生 HTML", isOn: $render.preferences.allowRawHTML)
                Toggle("硬换行(回车即换行)", isOn: $render.preferences.hardBreaks)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Rendering

private struct RenderingPage: View {
    @AppStorage(AppearanceKey.previewStyle) private var style = AppearanceDefault.previewStyle
    @AppStorage(AppearanceKey.previewStyleFollowsSystem) private var styleFollows = false
    @Bindable private var render = RenderSettings.shared

    var body: some View {
        Form {
            Section("预览") {
                Picker("预览样式", selection: $style) {
                    ForEach(PreviewStyles.all) { Text($0.name).tag($0.id) }
                }
                Toggle("跟随系统", isOn: $styleFollows)
            }
            Section("代码") {
                Toggle("代码高亮", isOn: $render.preferences.codeHighlighting)
                Toggle("显示行号", isOn: $render.preferences.codeLineNumbers)
            }
            Section("数学公式") {
                Toggle("渲染数学公式(KaTeX)", isOn: render.binding(.math))
                Toggle("行内 $…$ 也算公式", isOn: $render.preferences.inlineDollarMath)
                    .disabled(!render.preferences.extensions.contains(.math))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Updates

private struct UpdatesPage: View {
    @Bindable private var updater = UpdaterController.shared

    var body: some View {
        Form {
            Section {
                Toggle("自动检查更新", isOn: $updater.automaticallyChecks)
                Picker("检查频率", selection: $updater.checkInterval) {
                    ForEach(UpdaterController.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                .disabled(!updater.automaticallyChecks)
                Button("立即检查") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .disabled(!updater.isConfigured)
            if !updater.isConfigured {
                Section { Text("此构建没有配置更新签名公钥(SUPublicEDKey),更新检查已停用。").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
