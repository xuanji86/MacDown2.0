import Testing
import WorkspaceKit
@testable import CLIKit

@Test func noArgumentsOpensNothing() throws {
    #expect(try Arguments.parse([]) == .open(OpenArgs()))
}

@Test func filesAndFoldersAreOpenArguments() throws {
    #expect(try Arguments.parse(["a.md", ".", "../b.qmd"]) == .open(OpenArgs(paths: ["a.md", ".", "../b.qmd"])))
    #expect(try Arguments.parse(["open", "a.md"]) == .open(OpenArgs(paths: ["a.md"])))
    #expect(try Arguments.parse(["-"]) == .open(OpenArgs(paths: ["-"])))  // a lone dash is stdin, not an option
}

@Test func dryRunAndDoubleDash() throws {
    #expect(try Arguments.parse(["--dry-run", "a.md"]) == .open(OpenArgs(paths: ["a.md"], dryRun: true)))
    #expect(try Arguments.parse(["open", "a.md", "--dry-run"]) == .open(OpenArgs(paths: ["a.md"], dryRun: true)))
    // After `--` everything is a path, including names that look like options or subcommands.
    #expect(try Arguments.parse(["--", "-x.md", "--dry-run", "render"]) == .open(OpenArgs(paths: ["-x.md", "--dry-run", "render"])))
    #expect(try Arguments.parse(["open", "--", "render"]) == .open(OpenArgs(paths: ["render"])))
}

@Test func layoutFlags() throws {
    #expect(try Arguments.parse(["--preview-only", "a.md"]) == .open(OpenArgs(paths: ["a.md"], layout: .previewOnly)))
    #expect(try Arguments.parse(["a.md", "--editor-only"]) == .open(OpenArgs(paths: ["a.md"], layout: .editorOnly)))
    #expect(try Arguments.parse(["open", "--both", "a.md", "--dry-run"]) == .open(OpenArgs(paths: ["a.md"], dryRun: true, layout: .both)))
    #expect(try Arguments.parse(["--preview-only", "--preview-only", "a.md"]) == .open(OpenArgs(paths: ["a.md"], layout: .previewOnly)))  // the same twice is harmless
    #expect(try Arguments.parse(["a.md"]) == .open(OpenArgs(paths: ["a.md"], layout: nil)))
    // After `--` a file may be called anything.
    #expect(try Arguments.parse(["--", "--preview-only"]) == .open(OpenArgs(paths: ["--preview-only"])))
}

@Test func layoutFlagsAreMutuallyExclusive() {
    for combo in [["--preview-only", "--editor-only"], ["--editor-only", "--both"], ["--both", "--preview-only"]] {
        do {
            _ = try Arguments.parse(combo + ["a.md"])
            Issue.record("\(combo) should not parse")
        } catch let e as CLIError {
            #expect(e.code == 64)
            #expect(e.message == "\(combo[0]) and \(combo[1]) cannot be combined: pick one layout")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Test func layoutFlagsBelongToOpenOnly() {
    #expect(throws: CLIError.self) { try Arguments.parse(["render", "a.md", "--preview-only"]) }
}

@Test func helpDocumentsTheLayoutFlags() {
    for flag in ["--both", "--editor-only", "--preview-only"] { #expect(Arguments.help.contains(flag)) }
}

@Test func helpAndVersion() throws {
    #expect(try Arguments.parse(["--help"]) == .help)
    #expect(try Arguments.parse(["-h"]) == .help)
    #expect(try Arguments.parse(["a.md", "--help"]) == .help)
    #expect(try Arguments.parse(["render", "--help"]) == .help)
    #expect(try Arguments.parse(["--version"]) == .version)
}

@Test func renderArguments() throws {
    #expect(try Arguments.parse(["render", "a.md"]) == .render(RenderArgs(input: "a.md")))
    #expect(try Arguments.parse(["render", "a.md", "-o", "out.html", "--standalone"]) == .render(RenderArgs(input: "a.md", output: "out.html", standalone: true)))
    #expect(try Arguments.parse(["render", "--standalone", "--output=x.html", "a.qmd"]) == .render(RenderArgs(input: "a.qmd", output: "x.html", standalone: true)))
    #expect(try Arguments.parse(["render", "--output", "x.html", "--", "-odd.md"]) == .render(RenderArgs(input: "-odd.md", output: "x.html")))
}

@Test func badArgumentsAreUsageErrors() {
    func usage(_ args: [String]) -> Bool {
        do { _ = try Arguments.parse(args); return false } catch let e as CLIError { return e.code == 64 } catch { return false }
    }
    #expect(usage(["--bogus"]))
    #expect(usage(["open", "-x"]))
    #expect(usage(["render"]))  // no file
    #expect(usage(["render", "a.md", "b.md"]))
    #expect(usage(["render", "a.md", "-o"]))  // value missing
    #expect(usage(["render", "a.md", "--output="]))
    #expect(usage(["render", "a.md", "--dry-run"]))  // belongs to open
}
