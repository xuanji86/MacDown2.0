import Testing
@testable import MarkdownCore

@Test func withAutoRenderOnEveryChangeRenders() {
    #expect(PreviewRefresh.rendersOnEdit(autoRender: true, hasRendered: true))
    #expect(PreviewRefresh.rendersOnEdit(autoRender: true, hasRendered: false))
}

@Test func withAutoRenderOffAnEditDoesNotRender() {
    #expect(!PreviewRefresh.rendersOnEdit(autoRender: false, hasRendered: true))
}

@Test func withAutoRenderOffADocumentsFirstTextStillRenders() {
    // A new tab (or a freshly opened window) would otherwise show nothing, or the previous tab's page.
    #expect(PreviewRefresh.rendersOnEdit(autoRender: false, hasRendered: false))
}
