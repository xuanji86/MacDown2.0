import SwiftUI

@main
struct MacDown2App: App {
    init() { AppExtensions.start() }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
        .commands { AppearanceCommands() }
        Settings { EmptyView() }
    }
}
