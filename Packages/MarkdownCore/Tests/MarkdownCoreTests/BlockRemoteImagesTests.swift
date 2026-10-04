import Foundation
import Testing
import WebAssets
@testable import MarkdownCore

/// The print/PDF half of "Block remote images": the standalone page carries a CSP with no network origin only when asked.
@Test func blockRemoteImagesAddsANetworklessCSPToTheStandalonePage() {
    let body = #"<p><img src="https://tracker.example/a.png" alt="a"></p>"#
    let open = HTMLExporter.document(body: body, title: "t")
    #expect(!open.contains(RemoteContent.printContentSecurityPolicy))  // default: remote images load (the export still refuses script)

    let blocked = HTMLExporter.document(body: body, title: "t", blockRemoteImages: true)
    #expect(blocked.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(RemoteContent.printContentSecurityPolicy)">"#))
    let head = String(blocked[..<(blocked.range(of: "</head>")?.lowerBound ?? blocked.endIndex)])
    #expect(head.contains("Content-Security-Policy"))  // in <head>, before any resource is requested
    #expect(!RemoteContent.printContentSecurityPolicy.contains("http"))
}

@Test func theSettingsDefaultsDecideTheStyleAndTheRemoteImageSwitch() {
    let name = "BlockRemoteImagesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }

    let policy = #"content="\#(RemoteContent.printContentSecurityPolicy)""#
    #expect(!HTMLExporter.document(body: "<p>x</p>", title: "t", defaults: defaults).contains(policy))  // absent key: off
    #expect(!HTMLExporter.document(body: "<p>x</p>", title: "t", defaults: nil).contains(policy))
    defaults.set(true, forKey: RemoteContent.blockImagesKey)
    #expect(HTMLExporter.document(body: "<p>x</p>", title: "t", defaults: defaults).contains(policy))
    #expect(HTMLExporter.document(body: "<p>x</p>", title: "t", defaults: defaults).contains("script-src 'none'"))  // the export's own CSP stays

    defaults.set("solarized-light", forKey: PreviewStyles.styleKey)
    #expect(HTMLExporter.document(body: "<p>x</p>", title: "t", defaults: defaults) == HTMLExporter.document(
        body: "<p>x</p>", title: "t", style: PreviewStyles.resolve(id: "solarized-light", followSystem: false), blockRemoteImages: true))
}
