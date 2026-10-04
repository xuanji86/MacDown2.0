import Foundation
import MarkdownCore
import WebAssets

/// `macdown2 render <file>`: the app's renderer (JavaScriptCore), no app, no window.
enum Render {
    static func run(_ args: RenderArgs, host: CLIHost) async throws {
        let input = try CLI.resolve(args.input, host: host)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { throw CLIError(ExitCode.noInput, "\(args.input) is a folder, not a file") }
        let data: Data
        do { data = try Data(contentsOf: input) } catch { throw CLIError(ExitCode.noInput, "cannot read \(args.input): \(error.localizedDescription)") }
        // Same encoding detection as the app (UTF-8, UTF-16 with a BOM, GB18030, ...): a file that is no text at all is reported, never half-rendered.
        guard let file = try? MarkdownFile.decode(data) else { throw CLIError(ExitCode.noInput, "\(args.input) cannot be read as text") }

        // The app's settings when they can be read (another process's preference domain: a plain read, no sandbox here); otherwise the
        // defaults, which means every switch is on, Quarto included.
        let defaults = host.appDefaults()
        var options = defaults.map { RenderPreferences(defaults: $0).options } ?? RenderOptions()
        let manifest: FlavorManifest
        do { manifest = try FlavorManifest.bundled() } catch { throw CLIError(ExitCode.software, "cannot read the flavor manifest: \(error)") }
        // lazy: a `.qmd` is the only flavored type, so the extension decides the type; upgrade = UTType(filenameExtension:) once more flavors exist.
        let utType = input.pathExtension.lowercased() == "qmd" ? "org.quarto.qmd" : "net.daringfireball.markdown"
        let (flavor, chunks) = manifest.resolve(utType: utType) { defaults?.object(forKey: $0) as? Bool ?? true }
        options.flavor = flavor
        options.renderChunks = chunks
        // The renderer cannot read files: a Quarto document's `{{< include >}}` children are collected here, from the document's
        // folder only, with the same limits as in the app (QuartoIncludes: 64 files, 5 levels, no cycles, nothing outside the folder).
        // lazy: only Quarto includes files; upgrade = ask the flavor manifest, once a second flavor needs this.
        if flavor.rawValue == "quarto" {
            options.files = QuartoIncludes.files(for: file.text, readFile: QuartoIncludes.fileReader(directory: input.deletingLastPathComponent()))
        }
        let stylesheets = manifest.entries[flavor]?.stylesheets ?? []
        options = options.forExport  // the output goes to a file or a pipe: no script, frames or event handlers from the document

        let result: RenderResult
        do { result = try await JSCRenderer().render(file.text, options: options) } catch { throw CLIError(ExitCode.software, "rendering failed: \(error)") }

        let userCSS = try args.css.map { try stylesheet($0, host: host) }
        let text: String
        if args.isPage {
            let style = PreviewStyles.resolve(
                id: defaults?.string(forKey: PreviewStyles.styleKey) ?? PreviewStyles.defaultID,
                followSystem: defaults?.bool(forKey: PreviewStyles.followsSystemKey) ?? false
            )
            // A PDF is laid out from the page alone (no document folder behind it), so its images always travel inside it.
            let images = args.embedImages || args.export == .pdf ? HTMLExporter.imageSource(directory: input.deletingLastPathComponent()) : nil
            text = HTMLExporter.document(
                body: result.html, title: input.deletingPathExtension().lastPathComponent, style: style, inlineImages: images,
                flavor: flavor.rawValue, stylesheets: stylesheets, userCSS: userCSS
            )
        } else {
            let html = HTMLExporter.stripSourceLines(result.html)
            text = html.hasSuffix("\n") || html.isEmpty ? html : html + "\n"
        }

        if args.export == .pdf {
            guard let output = args.output else { throw CLIError(ExitCode.usage, "--export pdf needs -o <file.pdf>") }
            let setup = defaults.map { PageSetup(defaults: $0) } ?? PageSetup()
            let pdf: Data
            do { pdf = try await host.renderPDF(text, setup) } catch let error as CLIError { throw error } catch {
                throw CLIError(ExitCode.software, "could not write the PDF: \(error.localizedDescription)")
            }
            try write(pdf, to: output, host: host)
            return
        }
        guard let output = args.output else { host.out(text); return }
        try write(Data(text.utf8), to: output, host: host)
    }

    private static func write(_ data: Data, to output: String, host: CLIHost) throws {
        let target = output.hasPrefix("/") ? URL(fileURLWithPath: output) : URL(fileURLWithPath: output, relativeTo: host.currentDirectory)
        do { try data.write(to: target.standardizedFileURL, options: .atomic) } catch {
            throw CLIError(ExitCode.noInput, "cannot write \(output): \(error.localizedDescription)")
        }
    }

    /// The text of the one local file `--css` names. Nothing else is read or fetched on its behalf: a URL is refused, and so is an
    /// `@import` (it would pull in a second file, or a remote one, that nobody typed on the command line).
    // lazy: `url(...)` for a font or an image in it is not checked; a browser (HTML) or the hidden web view (PDF) loads it. Upgrade = refuse remote url().
    static func stylesheet(_ path: String, host: CLIHost) throws -> String {
        if path.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            throw CLIError(ExitCode.usage, "--css takes a local file, not a URL: \(path)")
        }
        let file = try CLI.resolve(path, host: host)
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw CLIError(ExitCode.noInput, "--css \(path) is not a file") }
        guard (values?.fileSize ?? 0) <= 1_000_000 else { throw CLIError(ExitCode.noInput, "--css \(path) is over 1 MB") }
        guard let data = try? Data(contentsOf: file), var css = String(data: data, encoding: .utf8) else {
            throw CLIError(ExitCode.noInput, "--css \(path) cannot be read as UTF-8 text")
        }
        if css.hasPrefix("\u{FEFF}") { css.removeFirst() }
        let withoutComments = css.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
        if withoutComments.range(of: "@import", options: .caseInsensitive) != nil {
            throw CLIError(ExitCode.usage, "--css \(path) uses @import, which is not followed: put its rules into the file")
        }
        return css
    }
}
