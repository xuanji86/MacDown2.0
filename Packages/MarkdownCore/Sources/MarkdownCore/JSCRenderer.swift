import Foundation
import JavaScriptCore
import WebAssets

public enum RenderError: Error, Equatable {
    case missingAsset(String)
    case script(String)
}

/// Runs `render.bundle.js` (and any flavor chunks) in a private JavaScriptCore context.
/// Used where there is no WebView: Quick Look, CLI, export, tests.
public actor JSCRenderer: MarkdownRenderer {
    private let context: JSContext
    private let resolveChunk: @Sendable (String) -> URL?
    private var loadedChunks: Set<String> = []

    public init(
        bundleURL: URL? = WebAssets.url("render.bundle.js"),
        resolveChunk: @escaping @Sendable (String) -> URL? = { WebAssets.url($0) }
    ) throws {
        guard let bundleURL else { throw RenderError.missingAsset("render.bundle.js") }
        let context: JSContext = JSContext()
        try Self.evaluate(contentsOf: bundleURL, in: context)
        self.context = context
        self.resolveChunk = resolveChunk
    }

    public func render(_ source: String, options: RenderOptions) throws -> RenderResult {
        // A chunk registers its flavor on load; evaluate each one at most once per context.
        for chunk in options.renderChunks where !loadedChunks.contains(chunk) {
            guard let url = resolveChunk(chunk) else { throw RenderError.missingAsset(chunk) }
            try Self.evaluate(contentsOf: url, in: context)
            loadedChunks.insert(chunk)
        }
        let optionsJSON = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        let output = context.objectForKeyedSubscript("MacDown2")
            .objectForKeyedSubscript("render")
            .call(withArguments: [source, optionsJSON])
        try Self.throwPendingException(in: context)
        guard let json = output?.toString() else { throw RenderError.script("render returned nothing") }
        return try JSONDecoder().decode(RenderResult.self, from: Data(json.utf8))
    }

    private static func evaluate(contentsOf url: URL, in context: JSContext) throws {
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        try throwPendingException(in: context)
    }

    private static func throwPendingException(in context: JSContext) throws {
        guard let exception = context.exception else { return }
        context.exception = nil
        throw RenderError.script(exception.toString())
    }
}
