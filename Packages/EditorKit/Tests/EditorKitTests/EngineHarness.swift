import Foundation
import SwiftTreeSitter
@testable import EditorKit

/// Drives `MarkdownHighlightEngine` the way `MarkdownHighlighter` does, without a view: the text lives here.
@MainActor
final class EngineHarness {
    let engine: MarkdownHighlightEngine
    private(set) var text: String
    private var pointSource: NSString = ""

    init(_ initial: String) async throws {
        text = ""
        let box = Box()
        engine = try MarkdownHighlightEngine(pointForOffset: { Point.at(utf16Offset: $0, in: box.harness?.pointSource ?? "") })
        box.harness = self
        engine.textProvider = { [unowned self] range in
            let ns = text as NSString
            return NSMaxRange(range) <= ns.length ? ns.substring(with: range) : nil
        }
        await replace(NSRange(location: 0, length: 0), with: initial)
    }

    private final class Box { weak var harness: EngineHarness? }

    /// One text edit, fed to the engine as the storage notification would.
    func replace(_ range: NSRange, with replacement: String) async {
        let old = text
        text = (old as NSString).replacingCharacters(in: range, with: replacement)
        pointSource = old as NSString
        engine.willChangeContent(in: range)
        let snapshot = NSMutableString(string: text).copy() as! NSString  // a native NSString, as NSTextStorage gives us
        pointSource = snapshot
        let delta = (replacement as NSString).length - range.length
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            engine.didChangeContent(to: snapshot, in: range, delta: delta) { done.resume() }
        }
    }

    func tokens(in range: NSRange? = nil, mode: HighlightExecutionMode = .asynchronous(prefetch: true)) async throws -> [HighlightToken] {
        let r = range ?? NSRange(location: 0, length: (text as NSString).length)
        return try await withCheckedThrowingContinuation { cont in
            engine.tokens(in: r, mode: mode) { cont.resume(with: $0) }
        }
    }

    /// "kind:covered text" strings for readable assertions.
    func slices(_ tokens: [HighlightToken]) -> [String] {
        tokens.map { "\($0.kind.rawValue):\((text as NSString).substring(with: $0.range))" }
    }
}
