import ExtensionAPI
import Foundation
import SwiftUI

/// Quarto `.qmd` support (PLAN 4.6): the approximate preview. On: `.qmd` documents render through `quarto.chunk.js`
/// (callouts, divs, cross-references, figures, code-cell headers, `{{< include >}}`) with `quarto-approx.css`, and the
/// editor gets the Quarto overlay. Off: nothing of it exists, `.qmd` is plain Markdown.
///
/// `init` and `activate` register and nothing else: no tool lookup, no process, no environment (a code review item,
/// and a test). The real rendering (M2) will look for `quarto` only when the user first asks for it.
@MainActor
public final class QuartoExtension: MacDown2Extension {
    public static let id: ExtensionID = "quarto"
    public static let displayName: LocalizedStringResource = "Quarto"
    public static let summary: LocalizedStringResource = "打开 .qmd 文档，近似预览 callout、交叉引用、代码单元和 include；不执行代码。"
    public static let enabledByDefault = true
    public static let disabledHint: LocalizedStringResource? = "启用 Quarto 扩展以获得 callout / 交叉引用预览"

    public required init() {}

    public func activate(host: any ExtensionHost) async {
        host.register(flavor: QuartoFlavor())
    }

    /// Nothing to stop: the flavor is a value, and the host drops it with the other registrations.
    public func deactivate() async {}

    public func settingsPane() -> AnyView? { AnyView(QuartoSettingsPane()) }
}

struct QuartoSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近似预览").font(.subheadline.weight(.medium))
            Text("支持 callout、div、span、引用与交叉引用、图表标题、网格表格、公式、shortcode 惰性标记，以及 ```{python}``` / ```{r}``` 代码单元（只高亮，不执行）和 {{< include >}}（限文档所在目录，最多 5 层）。")
            Text("不读取 _quarto.yml、_extensions 或 .bib，交叉引用编号显示为“?”。使用本机 Quarto 的真渲染将在后续版本加入。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
