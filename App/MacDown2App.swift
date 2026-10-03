import SwiftUI

@main
struct MacDown2App: App {
    init() { AppExtensions.start() }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1100, height: 700)  // wide enough for the whole toolbar
        .commands {
            AppearanceCommands()
            FormatCommands()
            ExportCommands()
        }
        Settings { SettingsView() }
    }
}
