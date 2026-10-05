import Foundation
import UniformTypeIdentifiers

/// What a navigation in the preview page does (ISSUE-REVIEW 3.D / 3.N). Pure: the app's navigation decider asks, then
/// performs the answer; every rule below is covered by `LinkPolicyTests`.
///
/// The page lives at `macdown2-res://app/preview.html`; the preview script resolves a relative `href` against the
/// document folder into a `file://` URL before the page shows it (`Web/src/preview/links.ts`), so a click arrives here
/// as one of: the page itself (an in-page anchor), an absolute `http(s)`/`mailto`, a `file://`, or something hostile
/// (`javascript:`, `data:`, `x-apple.systempreferences:`, our own scheme pointing somewhere else...).
///
/// A refusal only cancels that one navigation; the rendered page stays as it is.
public struct LinkPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        /// The page's own load or a `#fragment` inside it: WebKit scrolls to the `id` or `<a name>` itself.
        case allow
        /// A Markdown file inside the document or workspace folders: open it in the app (the existing open route).
        case openInApp(URL)
        /// Any other existing file or folder: ask first, then hand it to the system. Never an executable (`.refuse(.executable)`).
        case confirmOpenWithSystem(URL)
        /// `http`, `https`, `mailto`: the system's browser / mail app.
        case openExternally(URL)
        case refuse(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case executable  // an app, script, installer, disk image, binary...: never opened from a document
        case missing  // a link to a file that is not there; nothing is created
        case remoteHost  // `file://server/share/...`
        case unsupportedScheme  // `javascript:`, `data:`, `blob:`, custom app schemes, ...
        case notALink  // a navigation no click caused (script, meta refresh, form), or a click on our own scheme that is not an anchor
    }

    /// `macdown2-res://app/preview.html`.
    public let pageURL: URL
    /// The document's folder and the open workspace folders: `.md`/`.qmd` files under these open in the app.
    public let roots: [URL]

    public init(pageURL: URL, roots: [URL]) {
        self.pageURL = pageURL
        self.roots = roots
    }

    public func decide(_ url: URL, isLinkActivation: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == (pageURL.scheme?.lowercased() ?? "") {
            // The page itself: loading/reloading it is ours, a click on an anchor is an in-page scroll. Everything else
            // in this scheme (`macdown2-res://doc/x`, the page without a fragment, other app files) is not navigable.
            guard Self.withoutFragment(url) == Self.withoutFragment(pageURL) else { return .refuse(.notALink) }
            return !isLinkActivation || url.fragment != nil ? .allow : .refuse(.notALink)
        }
        if scheme == "about" { return isLinkActivation ? .refuse(.unsupportedScheme) : .allow }
        guard isLinkActivation else { return .refuse(.notALink) }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? .openExternally(url) : .refuse(.unsupportedScheme)
        case "mailto":
            return .openExternally(url)
        case "file":
            return decideFile(url)
        default:
            return .refuse(.unsupportedScheme)
        }
    }

    // MARK: Files

    /// The extensions the app opens as documents (Info.plist, `net.daringfireball.markdown` and `org.quarto.qmd`): the one list the
    /// preview links, the file tree (`FileTreeOptions`) and `macdown2://` links (`DeepLink`) all use.
    public static let documentExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "qmd"]

    private func decideFile(_ url: URL) -> Decision {
        guard url.host(percentEncoded: false).map({ $0.isEmpty || $0 == "localhost" }) ?? true else { return .refuse(.remoteHost) }
        // Standardize and resolve symlinks first, judge the real target: `notes.md -> /bin/sh` is a binary, not a note.
        let file = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else { return .refuse(.missing) }
        if !isDirectory.boolValue, Self.documentExtensions.contains(file.pathExtension.lowercased()), isInsideRoots(file) {
            return .openInApp(file)  // whatever its permission bits say (sync folders set the execute bit on everything)
        }
        if Self.isExecutable(file, isDirectory: isDirectory.boolValue) { return .refuse(.executable) }
        return .confirmOpenWithSystem(file)
    }

    private func isInsideRoots(_ file: URL) -> Bool {
        roots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    // MARK: Executables

    private static let dangerousExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "fish", "pl", "py", "rb", "scpt", "scptd",
        "applescript", "workflow", "action", "wflow", "osax", "jar", "exe", "bat", "cmd", "msi", "com", "vbs", "ps1",
        "pkg", "mpkg", "dmg", "iso", "kext", "plugin", "xpc", "appex", "prefpane", "saver", "service", "framework",
        "bundle", "dylib", "so", "webloc", "inetloc", "fileloc", "url", "mobileconfig", "configprofile",
    ]

    /// True for anything that would run code or install something when opened. Layers, each enough on its own:
    /// the extension, the system's type for it, packages, the execute bit on something that is not a plain document,
    /// and the file's first bytes (a Mach-O/ELF/PE binary or a `#!` script renamed to look harmless).
    static func isExecutable(_ file: URL, isDirectory: Bool) -> Bool {
        let ext = file.pathExtension.lowercased()
        if dangerousExtensions.contains(ext) { return true }
        let type = UTType(filenameExtension: ext)
        let risky: [UTType] = [.executable, .unixExecutable, .application, .applicationBundle, .script, .shellScript, .appleScript, .bundle, .package, .diskImage, .framework]
        if let type, risky.contains(where: { type.conforms(to: $0) }) { return true }
        let values = try? file.resourceValues(forKeys: [.isPackageKey, .isExecutableKey])
        if values?.isPackage == true { return true }
        if isDirectory { return false }
        let isDocument = type.map { $0.conforms(to: .content) } ?? false
        if values?.isExecutable == true && !isDocument { return true }
        return looksLikeProgram(file, withShebang: !isDocument || values?.isExecutable == true)
    }

    private static let magic: [[UInt8]] = [
        [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],  // Mach-O
        [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],  // universal binary / Java class
        [0x7F, 0x45, 0x4C, 0x46],  // ELF
        [0x4D, 0x5A],  // PE ("MZ")
    ]

    private static func looksLikeProgram(_ file: URL, withShebang: Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        let bytes = [UInt8](head)
        if magic.contains(where: { bytes.starts(with: $0) }) { return true }
        return withShebang && bytes.starts(with: [0x23, 0x21])
    }

    static func withoutFragment(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }
}
