import Foundation

/// Maps the path of a `macdown2-res://doc/<path>` request to a file inside the document's directory.
/// Foundation only, so `Scripts/test-doc-resolver.sh` can compile and test it without the app.
enum DocumentFileResolver {
    enum Result: Equatable {
        case file(URL)
        case forbidden  // tried to leave the document directory (`..`, or a symlink that points out of it)
        case notFound
    }

    /// `path` is `URL.path` of the request, i.e. already percent-decoded: `..%2f..%2fx` arrives as `/../../x`
    /// (a literal `../..` never gets here, the web view normalizes it first, PLAN 4.4.2 pitfall 3).
    /// Order matters: reject `..` components, resolve symlinks, only then compare against the resolved root.
    static func resolve(path: String, root: URL?) -> Result {
        guard let root else { return .notFound }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.contains(where: { $0 == ".." || $0.contains("\0") }) { return .forbidden }
        guard !parts.isEmpty else { return .notFound }

        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = parts.reduce(base) { $0.appending(path: String($1), directoryHint: .inferFromPath) }.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard file.path.hasPrefix(prefix) else { return .forbidden }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return .notFound }
        return .file(file)
    }
}
