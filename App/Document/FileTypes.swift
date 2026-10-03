import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations) so it resolves even where the system has no entry.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    /// Quarto publishes no UTI; `.qmd` is declared in Info.plist as a Markdown subtype (PLAN 4.2). Opening it always works;
    /// whether it gets Quarto rendering is the Quarto extension's business.
    static let quarto = UTType(importedAs: "org.quarto.qmd", conformingTo: .markdown)

    /// The type of a document file for choosing its flavor: by extension, so it does not depend on Launch Services having
    /// registered this app's declarations yet. Unsaved documents are Markdown.
    static func ofDocument(at url: URL?) -> UTType {
        guard let url else { return .markdown }
        if url.pathExtension.lowercased() == "qmd" { return .quarto }
        return UTType(filenameExtension: url.pathExtension) ?? .markdown
    }
}
