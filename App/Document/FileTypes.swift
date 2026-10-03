import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations) so it resolves even where the system has no entry.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}
