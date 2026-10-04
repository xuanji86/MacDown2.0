import Foundation
import Testing
import WebAssets
@testable import MarkdownCore

/// The print/PDF half of "Block remote images": the standalone page carries a CSP with no network origin only when asked.
@Test func blockRemoteImagesAddsANetworklessCSPToTheStandalonePage() {
    let body = #"<p><img src="https://tracker.example/a.png" alt="a"></p>"#
    let open = HTMLExporter.document(body: body, title: "t")
    #expect(!open.contains("Content-Security-Policy"))  // default: unchanged, remote images load

    let blocked = HTMLExporter.document(body: body, title: "t", blockRemoteImages: true)
    #expect(blocked.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(RemoteContent.printContentSecurityPolicy)">"#))
    let head = String(blocked[..<(blocked.range(of: "</head>")?.lowerBound ?? blocked.endIndex)])
    #expect(head.contains("Content-Security-Policy"))  // in <head>, before any resource is requested
    #expect(!RemoteContent.printContentSecurityPolicy.contains("http"))
}
