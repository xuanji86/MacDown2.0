import Foundation
import Testing
import WorkspaceKit
@testable import ExtensionAPI

struct SearchProviderTests {
    @Test func theBuiltinBackendIsAKeywordProviderThatIsAlwaysReady() async throws {
        let provider: any SearchProvider = BuiltinSearchBackend()
        #expect(provider.id == "builtin" && provider.badge == "内置")
        #expect(provider.capabilities == .keyword)
        #expect(try await provider.prepare(workspace: URL(filePath: "/")) == .ready)
    }

    @Test func itSearchesThroughTheProtocolAndBadgesItsHits() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ExtensionAPITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("one\nfind me\n".utf8).write(to: dir.appending(path: "a.md"))

        let provider: any SearchProvider = BuiltinSearchBackend()
        var hits: [SearchHit] = []
        for try await hit in provider.search(SearchQuery(text: "find"), in: dir) { hits.append(hit) }
        #expect(hits.map(\.line) == [2])
        #expect(hits.first?.source == provider.id)
        await provider.cancelAll()
    }
}
