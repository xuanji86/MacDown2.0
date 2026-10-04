import Testing
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
