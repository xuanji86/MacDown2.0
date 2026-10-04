import Foundation

/// The "Block remote images" switch (Settings > Rendering). Off by default: the app loads `https` images like other Markdown
/// editors do. On, the preview page's CSP loses its network origin, so no image request leaves the machine, and so does the
/// page that is printed or saved as PDF. Quick Look never loads remote content, whatever this says.
public enum RemoteContent {
    public static let blockImagesKey = "preview.blockRemoteImages"

    /// An absent key is off.
    public static func blocksImages(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: blockImagesKey) }

    /// `preview.html` with the network origin taken out of its `img-src` (the directive is rewritten whole, so a later edit to
    /// the page's list of origins cannot leave one behind). Everything else in the page is untouched.
    public static func previewPage(_ html: String, blockingImages: Bool) -> String {
        guard blockingImages else { return html }
        return html.replacingOccurrences(of: #"img-src[^;"]*"#, with: "img-src macdown2-res: data:", options: .regularExpression)
    }

    /// For the standalone page handed to the print/PDF path (`HTMLExporter.document(blockRemoteImages:)`): its images are
    /// `data:` URIs by then, so nothing needs a network origin.
    public static let printContentSecurityPolicy = "default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
}
