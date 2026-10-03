import ExtensionAPI
import Foundation
import MarkdownCore
import UniformTypeIdentifiers

/// The `quarto` flavor. `id`, `renderChunks` and `previewStylesheets` must equal `Web/src/quarto/manifest.json` (it is what
/// Quick Look and the CLI read without linking this module); a test compares them.
public struct QuartoFlavor: DocumentFlavor {
    /// Quarto publishes no UTI of its own; this one is declared in the app's Info.plist (PLAN 4.2).
    public static let typeIdentifier = "org.quarto.qmd"
    private static let qmd = UTType(importedAs: typeIdentifier, conformingTo: .plainText)

    public init() {}

    public var id: FlavorID { "quarto" }
    public var renderChunks: [String] { ["quarto.chunk.js"] }
    public var previewStylesheets: [String] { ["quarto-approx.css"] }

    public func matches(contentType: UTType) -> Bool {
        contentType.identifier == Self.typeIdentifier || contentType.conforms(to: Self.qmd)
    }

    public func editorDecorations(visibleLines: [Substring], firstLine: Int) -> [DecorationSpan] {
        QuartoDecorations.spans(in: visibleLines, firstLine: firstLine)
    }

    public func auxiliaryFiles(for markdown: String, readFile: (String) -> String?) -> [String: String] {
        QuartoIncludes.files(for: markdown, readFile: readFile)
    }

    public var badge: FlavorBadge? {
        FlavorBadge(title: "Quarto · 近似预览", help: "未执行代码、未应用项目配置")
    }
}
