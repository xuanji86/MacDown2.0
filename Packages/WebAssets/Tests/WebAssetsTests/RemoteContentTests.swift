import Foundation
import Testing
@testable import WebAssets

struct RemoteContentTests {
    private func previewHTML() throws -> String {
        try String(contentsOf: #require(WebAssets.url("preview.html")), encoding: .utf8)
    }

    private func policy(_ html: String) throws -> [String: String] {
        let content = try #require(html.firstMatch(of: /Content-Security-Policy" content="([^"]*)"/)).1
        var out: [String: String] = [:]
        for directive in content.split(separator: ";") {
            let parts = directive.split(separator: " ", maxSplits: 1).map(String.init)
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    @Test func imagesLoadFromTheNetworkByDefault() throws {
        let page = try previewHTML()
        #expect(RemoteContent.previewPage(page, blockingImages: false) == page)
        #expect(try policy(page)["img-src"]?.contains("https:") == true)
    }

    @Test func blockingDropsEveryNetworkOriginFromImgSrcAndNothingElse() throws {
        let page = try previewHTML()
        let blocked = RemoteContent.previewPage(page, blockingImages: true)
        let img = try #require(try policy(blocked)["img-src"])
        #expect(img == "macdown2-res: data:")
        #expect(!img.contains("http") && !img.contains("*"))
        var before = try policy(page), after = try policy(blocked)
        before["img-src"] = nil
        after["img-src"] = nil
        #expect(before == after)  // script-src (with its nonce token), style-src, ... as they were
    }

    @Test func theSettingDefaultsToOffAndReadsTheStoredValue() throws {
        let suite = "remote-content-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!RemoteContent.blocksImages(in: defaults))
        defaults.set(true, forKey: RemoteContent.blockImagesKey)
        #expect(RemoteContent.blocksImages(in: defaults))
    }

    @Test func thePrintPolicyHasNoNetworkOrigin() {
        #expect(!RemoteContent.printContentSecurityPolicy.contains("http"))
        #expect(!RemoteContent.printContentSecurityPolicy.contains("*"))
    }
}
