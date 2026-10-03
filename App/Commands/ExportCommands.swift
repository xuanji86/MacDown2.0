import SwiftUI

/// File > Export > HTML… / PDF…, and Print… / Page Setup… (the system ones are replaced so Print uses the same
/// paginated page as the PDF export).
struct ExportCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("Export") {
                Button("HTML…") { actions?.exportHTML() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("PDF…") { actions?.exportPDF() }
            }
            .disabled(actions == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { DocumentExport.pageSetup() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { actions?.printDocument() }
                .keyboardShortcut("p")
                .disabled(actions == nil)
        }
    }
}
