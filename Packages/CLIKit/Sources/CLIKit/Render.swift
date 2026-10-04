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
        let stylesheets = manifest.entries[flavor]?.stylesheets ?? []

        let result: RenderResult
        do { result = try await JSCRenderer().render(file.text, options: options) } catch { throw CLIError(ExitCode.software, "rendering failed: \(error)") }

        let text: String
        if args.standalone {
            let style = PreviewStyles.resolve(
                id: defaults?.string(forKey: PreviewStyles.styleKey) ?? PreviewStyles.defaultID,
                followSystem: defaults?.bool(forKey: PreviewStyles.followsSystemKey) ?? false
            )
            text = HTMLExporter.document(body: result.html, title: input.deletingPathExtension().lastPathComponent, style: style, flavor: flavor.rawValue, stylesheets: stylesheets)
        } else {
            let html = HTMLExporter.stripSourceLines(result.html)
            text = html.hasSuffix("\n") || html.isEmpty ? html : html + "\n"
        }

        guard let output = args.output else { host.out(text); return }
        let target = output.hasPrefix("/") ? URL(fileURLWithPath: output) : URL(fileURLWithPath: output, relativeTo: host.currentDirectory)
        do { try text.write(to: target.standardizedFileURL, atomically: true, encoding: .utf8) } catch {
            throw CLIError(ExitCode.noInput, "cannot write \(output): \(error.localizedDescription)")
        }
    }
}
