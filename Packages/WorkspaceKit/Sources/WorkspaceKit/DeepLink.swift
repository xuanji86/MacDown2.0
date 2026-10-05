import Foundation

/// A `macdown2://` link, checked. Pure parsing and validation: it never opens anything, and nothing in a link is ever executed.
///
///     macdown2://open?path=<absolute path>[&line=<N>][&layout=both|editor-only|preview-only]
///     macdown2://workspace?path=<absolute folder>[&layout=...]
///
/// `open` takes a file (a tab in the frontmost window, `line` selects that 1-based line) or a folder (workspace mode, as
/// `macdown2 <dir>` does); `workspace` takes only a folder. Other parameters are ignored.
///
/// What a link may open is narrower than what the command line or the Open panel may, because a link can come from a web page
/// or a chat message that the user did not write:
///   - only the `path`, absolute (starts with `/`; no `~`, no relative path), with no `..` component (refused, not normalised),
///     no control character and at most `maxPathLength` bytes. No `file:` URL, no host, no remote location, no command;
///   - the path must exist, and be a folder or a file whose extension (also after resolving symlinks) is a Markdown / Quarto /
///     plain-text one, so a link cannot show `~/.ssh/id_rsa` or launch an app bundle;
///   - each parameter at most once; `line` is digits only and at most `maxLine`.
/// There is no confirmation dialog: opening shows text (the preview never executes code, and Quarto's real render is its own
/// opt-in), and the app's sandbox-free reach is the same one the Open panel has. An isolated test launch additionally
/// refuses paths outside its root, in the app (`AppDefaults.permitsOpening`).
public struct DeepLink: Equatable, Sendable {
    public static let scheme = "macdown2"
    public static let maxPathLength = 1024
    public static let maxLine = 10_000_000
    /// What a link may open as a file: what the sidebar opens (`FileTreeOptions.openableExtensions`), so a link can never reach a
    /// file the app would not open from its own tree.
    public static var fileExtensions: Set<String> { FileTreeOptions.openableExtensions }

    public enum Failure: Error, Equatable, Sendable {
        /// Not `macdown2:`, or an action other than `open` / `workspace`, or something after the action (`macdown2://open/x`).
        case unsupportedLink
        /// A parameter that is empty or given twice, a bad `line` / `layout`, or `workspace` without a folder.
        case badParameter(String)
        /// Not an absolute path, or one with `..`, a control character or an absurd length.
        case unsafePath
        case notFound
        /// A file that is not Markdown, Quarto or text.
        case unsupportedFileType
    }

    public enum Kind: Equatable, Sendable { case file, folder }

    /// The standardized absolute file URL (not symlink-resolved: tabs and the ledger are keyed by what the user named).
    public let url: URL
    public let kind: Kind
    /// 1-based; files only.
    public let line: Int?
    public let layout: SplitMode?

    /// What exists at `url`: nil = nothing. The default asks the file system, a folder meaning a directory that is not a package.
    public static func fileSystemKind(_ url: URL) -> Kind? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return OpenRouter.isFolder(url) ? .folder : .file
    }

    public static func parse(_ link: URL, kind: (URL) -> Kind? = DeepLink.fileSystemKind) -> Result<DeepLink, Failure> {
        do { return .success(try validate(link, kind: kind)) } catch { return .failure(error as? Failure ?? .unsupportedLink) }
    }

    private static func validate(_ link: URL, kind lookup: (URL) -> Kind?) throws -> DeepLink {
        guard link.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let action = parts.host?.lowercased(), action == "open" || action == "workspace",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/"
        else { throw Failure.unsupportedLink }

        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] where ["path", "line", "layout"].contains(item.name) {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else { throw Failure.badParameter(item.name) }
            values[item.name] = value
        }

        guard let path = values["path"] else { throw Failure.badParameter("path") }
        guard path.hasPrefix("/"), path.utf8.count <= maxPathLength,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
        else { throw Failure.unsafePath }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let kind = lookup(url) else { throw Failure.notFound }
        if kind == .file {
            // The name as given and the file it points to both have to be documents; `resolvingSymlinksInPath` leaves a path that does not resolve alone.
            guard [url, url.resolvingSymlinksInPath()].allSatisfy({ fileExtensions.contains($0.pathExtension.lowercased()) }) else { throw Failure.unsupportedFileType }
        }
        if action == "workspace", kind != .folder { throw Failure.badParameter("path") }

        var line: Int?
        if let text = values["line"], kind == .file {
            guard text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(text), (1...maxLine).contains(n) else { throw Failure.badParameter("line") }
            line = n
        }
        var layout: SplitMode?
        if let text = values["layout"] {
            switch text {
            case "both": layout = .both
            case "editor-only": layout = .editorOnly
            case "preview-only": layout = .previewOnly
            default: throw Failure.badParameter("layout")
            }
        }
        return DeepLink(url: url, kind: kind, line: line, layout: layout)
    }
}
