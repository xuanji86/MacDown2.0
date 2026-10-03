import AppKit
import MarkdownCore
import OSLog
import UniformTypeIdentifiers
import WebAssets

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "export")

/// File > Export > HTML… / PDF… and File > Print…. Renders with the current settings (`RenderSettings.current`) and the
/// preview style that is selected now; pass `options` to override the former.
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
            let printable = PrintPage()
            // Images are always embedded here: the offscreen page has no document folder to read them from.
            try await printable.load(html: try await page(markdown, fileURL: fileURL, options: options, embedImages: true))
            let info = PrintPage.printInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            if !(await printable.run(info: info, panel: false)) { throw CocoaError(.fileWriteUnknown) }
        } catch {
            fail("Could not export PDF", error, window: window)
        }
    }

    /// The system print panel as a sheet on the document window, then the same paginated output as the PDF.
    static func print(_ markdown: String, fileURL: URL?, options: RenderOptions = RenderSettings.current, window: NSWindow? = NSApp.keyWindow) async {
        do {
            let printable = PrintPage()
            try await printable.load(html: try await page(markdown, fileURL: fileURL, options: options, embedImages: true))
            _ = await printable.run(info: PrintPage.printInfo(), panel: true, sheetWindow: window)
        } catch {
            fail("Could not print", error, window: window)
        }
    }

    static func pageSetup() {
        NSPageLayout().runModal(with: .shared)
    }

    // MARK: Pieces

    private static func page(_ markdown: String, fileURL: URL?, options: RenderOptions, embedImages: Bool) async throws -> String {
        let body = try await CopyHTML.render(markdown, options: options)
        let defaults = UserDefaults.standard
        let style = PreviewStyles.resolve(
            id: defaults.string(forKey: AppearanceKey.previewStyle) ?? AppearanceDefault.previewStyle,
            followSystem: defaults.bool(forKey: AppearanceKey.previewStyleFollowsSystem)
        )
        return HTMLExporter.document(
            body: body, title: fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled", style: style,
            inlineImages: embedImages ? imageSource(directory: fileURL?.deletingLastPathComponent()) : nil
        )
    }

    /// Same containment rules as the preview's `macdown2-res://doc/` handler: nothing outside the document folder.
    static func imageSource(directory: URL?) -> HTMLExporter.ImageSource {
        { path in
            guard case .file(let file) = DocumentFileResolver.resolve(path: "/" + path, root: directory),
                  let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
                  let data = try? Data(contentsOf: file)
            else { return nil }
            return (data, mime)
        }
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
        checkbox.state = UserDefaults.standard.bool(forKey: DocumentExport.embedImagesKey) ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        checkbox.frame = NSRect(x: 12, y: 8, width: 400, height: 20)
        box.addSubview(checkbox)
        view = box
        super.init()
        checkbox.target = self
        checkbox.action = #selector(changed)
    }

    @objc private func changed() {
        UserDefaults.standard.set(isOn, forKey: DocumentExport.embedImagesKey)
    }
}
