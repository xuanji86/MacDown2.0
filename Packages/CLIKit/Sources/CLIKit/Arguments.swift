import Foundation
import WorkspaceKit

/// sysexits.h values, as promised in `--help`.
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let usage: Int32 = 64  // bad arguments
    public static let noInput: Int32 = 66  // a file cannot be found, read or written
    public static let unavailable: Int32 = 69  // the app could not be launched
    public static let software: Int32 = 70  // the renderer failed
}

/// A failure that ends the run with a message on stderr and `code`.
public struct CLIError: Error, Equatable {
    public let code: Int32
    public let message: String
    public init(_ code: Int32, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum Command: Equatable {
    case help
    case version
    case open(OpenArgs)
    case render(RenderArgs)
}

public struct OpenArgs: Equatable {
    /// As typed; `-` means "the text on stdin".
    public var paths: [String] = []
    public var dryRun = false
    /// `--both`, `--editor-only`, `--preview-only`: the layout of the window the files open in; nil = the app decides.
    public var layout: SplitMode?
}

public struct RenderArgs: Equatable {
    public enum Format: String, Equatable, Sendable { case html, pdf }

    public var input = ""
    public var output: String?
    public var standalone = false
    /// `--export html|pdf`. html is a complete page (so `--standalone`); pdf needs `-o`.
    public var export: Format?
    /// `--css file.css`: the user's own stylesheet, inlined last. A path, as typed.
    public var css: String?
    /// `--embed-images`: document-relative images become `data:` URIs, so the page does not depend on the folder.
    public var embedImages = false

    /// A complete page rather than the bare fragment: each of these needs a page to hang on.
    public var isPage: Bool { standalone || export != nil || css != nil || embedImages }
}

extension SplitMode {
    /// The command line spelling.
    var flag: String {
        switch self {
        case .both: "--both"
        case .editorOnly: "--editor-only"
        case .previewOnly: "--preview-only"
        }
    }
}

/// Hand-written on purpose (PLAN 4.10): two subcommands and four flags do not justify a dependency.
public enum Arguments {
    public static func parse(_ args: [String]) throws -> Command {
        switch args.first {
        case "render": return try parseRender(args.dropFirst())
        case "open": return try parseOpen(args.dropFirst())
        default: return try parseOpen(args[...])  // `open` is the default; a file literally named "render" is `./render` or `-- render`
        }
    }

    private static func parseOpen(_ args: ArraySlice<String>) throws -> Command {
        var out = OpenArgs()
        var literal = false
        for arg in args {
            if literal || arg == "-" || !arg.hasPrefix("-") { out.paths.append(arg); continue }
            switch arg {
            case "--": literal = true
            case "-h", "--help": return .help
            case "--version": return .version
            case "--dry-run": out.dryRun = true
            case "--both", "--editor-only", "--preview-only":
                let mode = SplitMode.allCases.first { $0.flag == arg }!
                if let earlier = out.layout, earlier != mode {
                    throw CLIError(ExitCode.usage, "\(earlier.flag) and \(arg) cannot be combined: pick one layout")
                }
                out.layout = mode
            default: throw unknown(arg)
            }
        }
        return .open(out)
    }

    private static func parseRender(_ args: ArraySlice<String>) throws -> Command {
        var out = RenderArgs()
        var input: String?
        var literal = false
        var it = args.makeIterator()
        while let arg = it.next() {
            if literal || arg == "-" || !arg.hasPrefix("-") {
                guard input == nil else { throw CLIError(ExitCode.usage, "render takes one file, got a second: \(arg)") }
                input = arg
                continue
            }
            switch arg {
            case "--": literal = true
            case "-h", "--help": return .help
            case "--standalone": out.standalone = true
            case "--embed-images": out.embedImages = true
            case "-o", "--output":
                guard let value = it.next(), !value.isEmpty else { throw CLIError(ExitCode.usage, "\(arg) needs a file name") }
                out.output = value
            case "--export":
                guard let value = it.next() else { throw CLIError(ExitCode.usage, "--export needs html or pdf") }
                out.export = try format(value)
            case "--css":
                guard let value = it.next(), !value.isEmpty else { throw CLIError(ExitCode.usage, "--css needs a file name") }
                out.css = value
            default:
                if arg.hasPrefix("--output="), arg.count > "--output=".count {
                    out.output = String(arg.dropFirst("--output=".count))
                } else if arg.hasPrefix("--export=") {
                    out.export = try format(String(arg.dropFirst("--export=".count)))
                } else if arg.hasPrefix("--css="), arg.count > "--css=".count {
                    out.css = String(arg.dropFirst("--css=".count))
                } else {
                    throw unknown(arg)
                }
            }
        }
        guard let input, !input.isEmpty else {
            throw CLIError(ExitCode.usage, "render needs a file: macdown2 render <file> [-o out.html] [--export html|pdf] [--css file.css]")
        }
        if out.export == .pdf, out.output == nil { throw CLIError(ExitCode.usage, "--export pdf needs -o <file.pdf>: a PDF is not printed to the terminal") }
        out.input = input
        return .render(out)
    }

    private static func format(_ value: String) throws -> RenderArgs.Format {
        guard let format = RenderArgs.Format(rawValue: value.lowercased()) else {
            throw CLIError(ExitCode.usage, "--export takes html or pdf, not \(value.isEmpty ? "nothing" : value)")
        }
        return format
    }

    private static func unknown(_ arg: String) -> CLIError {
        CLIError(ExitCode.usage, "unknown option \(arg) (see macdown2 --help; put -- before a file name that starts with a dash)")
    }

    public static let help = """
    macdown2: command line for MacDown2.0

    USAGE
      macdown2 [--dry-run] [--both|--editor-only|--preview-only] [<file-or-folder>…]
                                                 open in MacDown2.0 (a folder opens as a workspace)
      macdown2 open [--dry-run] [--] <path>…     the same, spelled out
      macdown2 render <file> [-o out.html] [--standalone] [--css file.css] [--embed-images]
                                                 render to HTML here, without starting the app
      macdown2 render <file> --export html|pdf [-o out] [--css file.css]
                                                 a complete HTML page or a paginated PDF, like File > Export
      macdown2 --help | --version

    STDIN
      cat notes.md | macdown2     text piped in (or `macdown2 -`) is saved to
                                  ~/Library/Caches/io.github.xuanji86.MacDown2/stdin/<timestamp>.md
                                  and that file is opened, because MacDown2.0 has no untitled documents.
                                  Use Save As… in the app to keep it; the cache folder is not a place to keep things.

    OPTIONS
      --dry-run      print the `open` command instead of running it (piped text is still saved)
      --both, --editor-only, --preview-only
                     the layout of the window the files open in (editor and preview, editor only, preview only);
                     one of them at most, and it needs a file or folder. Without one, the window uses its own last
                     layout, or the "Layout for new windows" setting. Works whether the app is running or not.
      -o, --output   write the HTML to a file instead of stdout (required for pdf)
      --standalone   a complete page with the preview style inlined (default: the HTML fragment only);
                     .qmd files render as Quarto unless it is switched off in MacDown2.0 > Settings
      --export html|pdf
                     html is a complete page (like --standalone). pdf is paginated with the paper size, orientation
                     and margins of MacDown2.0 > Settings > Export (US Letter or A4 and 3/4 in until set), always in
                     the style's light colours. It is drawn by a hidden WebKit view inside this process: no app, no
                     window, no Dock icon, but it needs a logged-in macOS session (not plain ssh or a launchd daemon).
                     A page break written \\newpage, {{< pagebreak >}} or <div style="page-break-after: always"></div>
                     starts a new page.
      --css file.css
                     your stylesheet, added after the preview style and the print rules (implies a complete page).
                     Only that one local file is read: a URL is refused, and so is an @import in it (inline the rules).
      --embed-images
                     put document-relative images into the page as data: URIs (a PDF always does)

    ENVIRONMENT
      MACDOWN2_DEFAULTS_SUITE, MACDOWN2_ALLOWED_ROOT
                     for test launches of a Debug build (Scripts/run-isolated.sh): forwarded to a new app instance; `render` reads the
                     settings from that suite instead of the app's own
      MACDOWN2_STDIN_DIR
                     where piped text is saved (default: the cache folder above)

    EXIT STATUS
      0 ok   64 bad arguments   66 file missing, unreadable or unwritable
      69 the app could not be launched   70 rendering failed
    """
}
