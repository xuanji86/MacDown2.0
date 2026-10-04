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
    public static let displayName = L10n.resource("Quarto")
    public static let summary = L10n.resource("Opens .qmd documents and previews callouts, cross-references, code cells and includes approximately; code is never run.")
    public static let enabledByDefault = true
    public static let disabledHint: LocalizedStringResource? = L10n.resource("Turn on the Quarto extension to preview callouts and cross-references")

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
            Text("Approximate Preview", bundle: .module).font(.subheadline.weight(.medium))
            Text("Supports callouts, divs, spans, citations and cross-references, figure and table captions, grid tables, equations, inert shortcode markers, ```{python}``` / ```{r}``` code cells (highlighted only, never run) and {{< include >}} (limited to the document’s folder, at most 5 levels deep).", bundle: .module)
            Text("_quarto.yml, _extensions and .bib files are not read, and cross-reference numbers show as “?”. Real rendering with your local Quarto will come in a later version.", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
