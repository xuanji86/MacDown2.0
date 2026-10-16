import Foundation

/// Maps the path of a `macdown2-res://doc/<path>` request to a file inside the document's directory.
/// Shared by the app (preview scheme handler, export) and the Quick Look extension; tests in `DocumentFileResolverTests`.
public enum DocumentFileResolver {
    public enum Result: Equatable, Sendable {
        case file(URL)
        case forbidden  // tried to leave the document directory (`..`, or a symlink that points out of it)
        case notFound
    }

    /// `path` is `URL.path` of the request, i.e. already percent-decoded: `..%2f..%2fx` arrives as `/../../x`
    /// (a literal `../..` never gets here, the web view normalizes it first, PLAN 4.4.2 pitfall 3).
    /// Order matters: reject `..` components, resolve symlinks, only then compare against the resolved root.
    public static func resolve(path: String, root: URL?) -> Result {
        guard let root else { return .notFound }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.contains(where: { $0 == ".." || $0.contains("\0") }) { return .forbidden }
        guard !parts.isEmpty else { return .notFound }

        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = parts.reduce(base) { $0.appending(path: String($1), directoryHint: .inferFromPath) }.resolvingSymlinksInPath()
        guard file.isInside(base) else { return .forbidden }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return .notFound }
        return .file(file)
    }
}

extension URL {
    /// Whether this file URL lies under `root`: its path starts with the root's path and a `/`, so `/a/bc` is not inside `/a/b`, and a
    /// root with a trailing slash or `/` itself works. `orSame` also accepts the root's own path. A path comparison only: both sides
    /// must be standardized and symlink-resolved by the caller, which is what makes the answer about the real location.
    func isInside(_ root: URL, orSame: Bool = false) -> Bool {
        let base = root.path
        return (orSame && path == base) || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
