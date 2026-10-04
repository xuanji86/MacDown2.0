import AppKit
import MarkdownCore
import OSLog
import PrintKit
import UniformTypeIdentifiers
import WebAssets

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "export")

/// File > Export > HTML… / PDF… and File > Print…. Renders with the current settings (`RenderSettings.current`) and the
/// preview style that is selected now; pass `options` to override the former. Paper, orientation and margins of the PDF and
/// of the printout are Settings > Export (`PageSetup`).
@MainActor
enum DocumentExport {
    /// Checkbox in the HTML save panel: embed document-relative images as data URIs (default: keep the paths).
    static let embedImagesKey = "export.embedImages"

    static func html(of markdown: String, fileURL: URL?, options: RenderOptions = RenderSettings.current, window: NSWindow? = NSApp.keyWindow) async {
        let embed = EmbedImagesAccessory()
        guard let url = await save(.html, name: fileURL, window: window, accessory: embed.view) else { return }
        do {
            let page = try await page(markdown, fileURL: fileURL, options: options, embedImages: embed.isOn)
            try page.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not export HTML", error, window: window)
        }
    }

    static func pdf(of markdown: String, fileURL: URL?, options: RenderOptions = RenderSettings.current, window: NSWindow? = NSApp.keyWindow) async {
        guard let url = await save(.pdf, name: fileURL, window: window) else { return }
        do {
            // Images are always embedded here: the offscreen page has no document folder to read them from.
            let html = try await page(markdown, fileURL: fileURL, options: options, embedImages: true)
            try await PrintPage.pdf(html: html, setup: PageSetup(defaults: AppDefaults.store)).write(to: url, options: .atomic)
        } catch {
            fail("Could not export PDF", error, window: window)
        }
    }

    /// The system print panel as a sheet on the document window, then the same paginated output as the PDF.
    static func print(_ markdown: String, fileURL: URL?, options: RenderOptions = RenderSettings.current, window: NSWindow? = NSApp.keyWindow) async {
        do {
            let printable = PrintPage()
            try await printable.load(html: try await page(markdown, fileURL: fileURL, options: options, embedImages: true))
            _ = await printable.run(info: PrintPage.printInfo(PageSetup(defaults: AppDefaults.store)), panel: true, sheetWindow: window)
        } catch {
            fail("Could not print", error, window: window)
        }
    }

    /// The system Page Setup sheet on the settings of Settings > Export; what the user confirms there is written back to them,
    /// so there is one place that says what the paper is. (A paper size that is not one of `PageSetup.Paper` keeps the old one.)
    static func pageSetup() {
        let current = PageSetup(defaults: AppDefaults.store)
        let info = PrintPage.printInfo(current)
        guard NSPageLayout().runModal(with: info) == NSApplication.ModalResponse.OK.rawValue else { return }
        PrintPage.pageSetup(from: info, previous: current).write(to: AppDefaults.store)
    }

    // MARK: Pieces

    private static func page(_ markdown: String, fileURL: URL?, options: RenderOptions, embedImages: Bool) async throws -> String {
        let body = try await CopyHTML.render(markdown, options: options, fileURL: fileURL)  // sanitized: this leaves the app
        let flavor = AppExtensions.flavor(for: fileURL)
        let defaults = AppDefaults.store
        // "Block remote images" (Settings > Rendering) is in `defaults`; with it on the page's CSP has no network origin and no file
        // path either, so the images of the document travel inside the page whatever the Export HTML checkbox says.
        let embedImages = embedImages || RemoteContent.blocksImages(in: defaults)
        return HTMLExporter.document(
            body: body, title: fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled", defaults: defaults,
            inlineImages: embedImages ? HTMLExporter.imageSource(directory: fileURL?.deletingLastPathComponent()) : nil,
            flavor: flavor?.id.rawValue ?? "markdown", stylesheets: flavor?.previewStylesheets ?? []
        )
    }

    private static func save(_ type: UTType, name: URL?, window: NSWindow?, accessory: NSView? = nil) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (name?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + (type.preferredFilenameExtension ?? "")
        panel.directoryURL = name?.deletingLastPathComponent()
        panel.accessoryView = accessory
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } } else { panel.begin { continuation.resume(returning: $0) } }
        }
        return response == .OK ? panel.url : nil
    }

    private static func fail(_ message: String, _ error: any Error, window: NSWindow?) {
        log.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert(error: error)
        alert.messageText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// "Embed images in the file" under the HTML save panel; remembers the last choice.
@MainActor
private final class EmbedImagesAccessory: NSObject {
    let view: NSView
    private let checkbox: NSButton

    var isOn: Bool { checkbox.state == .on }

    override init() {
        checkbox = NSButton(checkboxWithTitle: "Embed images in the file (otherwise keep their relative paths)", target: nil, action: nil)
        checkbox.state = AppDefaults.store.bool(forKey: DocumentExport.embedImagesKey) ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        checkbox.frame = NSRect(x: 12, y: 8, width: 400, height: 20)
        box.addSubview(checkbox)
        view = box
        super.init()
        checkbox.target = self
        checkbox.action = #selector(changed)
    }

    @objc private func changed() {
        AppDefaults.store.set(isOn, forKey: DocumentExport.embedImagesKey)
    }
}
