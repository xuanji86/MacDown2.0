import ExtensionAPI
import Foundation
import SwiftUI

/// Quarto `.qmd` support (PLAN 4.6): the approximate preview, and the real render with the user's own Quarto. On: `.qmd` documents
/// render through `quarto.chunk.js` (callouts, divs, cross-references, figures, code-cell headers, `{{< include >}}`) with
/// `quarto-approx.css`, the editor gets the Quarto overlay, and the preview offers `Approximate | Quarto`. Off: nothing of it exists,
/// `.qmd` is plain Markdown.
///
/// `init` and `activate` register and nothing else: no tool lookup, no process, no environment (a code review item, and a test).
/// `quarto` is looked for only when the user first switches a preview to Quarto or opens these settings.
@MainActor
public final class QuartoExtension: MacDown2Extension {
    public static let id: ExtensionID = "quarto"
    public static let displayName = L10n.resource("Quarto")
    public static let summary = L10n.resource("Opens .qmd documents and previews callouts, cross-references, code cells and includes approximately; code is never run.")
    public static let enabledByDefault = true
    public static let disabledHint: LocalizedStringResource? = L10n.resource("Turn on the Quarto extension to preview callouts and cross-references")

    /// While active.
    private(set) var realRender: QuartoRealRender?

    public required init() {}

    public func activate(host: any ExtensionHost) async {
        let realRender = QuartoRealRender(settings: host.settings, toolEnvironment: host.toolEnvironment)
        self.realRender = realRender
        host.register(flavor: QuartoFlavor(realRender: realRender))
    }

    /// Stops every real-render process (SIGTERM, SIGKILL after 3 s); the host drops the flavor with the other registrations.
    public func deactivate() async {
        let realRender = realRender
        self.realRender = nil
        await realRender?.stopAll()
    }

    public func settingsPane() -> AnyView? { AnyView(QuartoSettingsPane(realRender: realRender)) }
}

struct QuartoSettingsPane: View {
    let realRender: QuartoRealRender?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Approximate Preview", bundle: .module).font(.subheadline.weight(.medium))
                Text("Supports callouts, divs, spans, citations and cross-references, figure and table captions, grid tables, equations, inert shortcode markers, ```{python}``` / ```{r}``` code cells (highlighted only, never run) and {{< include >}} (limited to the document’s folder, at most 5 levels deep).", bundle: .module)
                Text("_quarto.yml, _extensions and .bib files are not read, and cross-reference numbers show as “?”.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            if let realRender { RealRenderSettings(realRender: realRender) }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Quarto real render": the switch, "ask before rendering", which quarto (looked for when this first shows, and only with the switch
/// on), the manual path, and QUARTO_PYTHON / QUARTO_R as the login shell has them.
private struct RealRenderSettings: View {
    @Bindable var realRender: QuartoRealRender
    @State private var path = ""
    @State private var looking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $realRender.isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quarto Real Render", bundle: .module).font(.subheadline.weight(.medium))
                    Text("Renders the document with the Quarto installed on this Mac when you switch the preview to Quarto (⌘⌥R). The document’s code runs then, and only then.", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
            if realRender.isOn {
                Toggle(isOn: $realRender.asksEveryTime) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask Before Rendering", bundle: .module)
                        Text("Once per opened document, before Quarto first runs its code.", bundle: .module).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    found.multilineTextAlignment(.trailing).textSelection(.enabled)
                } label: {
                    Text("Quarto", bundle: .module)
                }
                LabeledContent {
                    TextField(text: $path, prompt: Text("Automatic", bundle: .module)) { Text("Quarto Path", bundle: .module) }
                        .labelsHidden()
                        .onSubmit { apply(path) }
                } label: {
                    Text("Quarto Path", bundle: .module)
                }
                ForEach(["QUARTO_PYTHON", "QUARTO_R"], id: \.self) { name in
                    LabeledContent {
                        if let value = realRender.environmentValues[name] {
                            Text(verbatim: value).textSelection(.enabled)
                        } else {
                            Text("Not set", bundle: .module).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(verbatim: name).monospaced()
                    }
                }
                HStack {
                    Text("Read from your login shell; set them in your shell configuration.", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { look(force: true) } label: { Text("Check Again", bundle: .module) }
                        .disabled(looking)
                }
            }
        }
        .onAppear { path = realRender.manualPath }
        // The first time these settings show (with the switch on), and when it is switched on here.
        .task(id: realRender.isOn) { if realRender.isOn { look(force: false) } }
    }

    @ViewBuilder private var found: some View {
        switch realRender.lookup {
        case nil:
            Text("Looking for Quarto…", bundle: .module).foregroundStyle(.secondary)
        case .found(let location)?:
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(location.version) · \(location.path)")
                Text(sourceLabel(location.source), bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        case .notFound(let reason)?:
            Text(verbatim: reason).foregroundStyle(.red)
        }
    }

    private func sourceLabel(_ source: QuartoLocation.Source) -> LocalizedStringKey {
        switch source {
        case .manual: "Set manually"
        case .loginPath: "On the login shell’s PATH"
        case .fallbackDirectory: "In a standard install folder"
        }
    }

    private func apply(_ newPath: String) {
        realRender.manualPath = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        look(force: true)
    }

    private func look(force: Bool) {
        looking = true
        Task {
            await realRender.probeForSettings(force: force)
            looking = false
        }
    }
}
