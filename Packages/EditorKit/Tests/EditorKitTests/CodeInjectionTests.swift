import AppKit
import Foundation
import Testing
@testable import EditorKit

struct InjectedLanguageTests {
    @Test(arguments: [
        ("python", InjectedLanguage.python), ("Python", .python), ("py", .python), ("python3", .python), ("{python}", .python),
        ("{python, echo=FALSE}", .python), ("{.python .numberLines}", .python), (" {python} ", .python),
        ("r", .r), ("R", .r), ("{r}", .r), ("{r, echo=FALSE}", .r), ("{r label=fig-x}", .r),
        ("yaml", .yaml), ("yml", .yaml), ("{yaml}", .yaml),
    ])
    func infoStringsThatNameALanguage(_ info: String, _ expected: InjectedLanguage) {
        #expect(InjectedLanguage.named(infoString: info) == expected)
    }

    @Test(arguments: ["", "swift", "{julia}", "{ojs}", "rust", "python-ish", "rr", "{}", "{.}", "js {python}", "{{python}}"])
    func otherInfoStringsAreNotInjected(_ info: String) {
        #expect(InjectedLanguage.named(infoString: info) == nil)
    }

    @Test func frontMatterYAMLIsWhatLiesBetweenTheDelimiters() {
        func yaml(_ block: String) -> String? {
            InjectedLanguage.yamlRange(ofFrontMatter: block as NSString).map { (block as NSString).substring(with: $0) }
        }
        #expect(yaml("---\ntitle: x\nformat: html\n---\n") == "title: x\nformat: html\n")
        #expect(yaml("---\ntitle: x\n---") == "title: x\n")
        #expect(yaml("---\ntitle: x\n...\n") == "title: x\n")
        #expect(yaml("---\ntitle: x\n") == "title: x\n")  // not closed (yet): the rest is still YAML
        #expect(yaml("---\n---\n") == nil)
        #expect(yaml("---\n") == nil)
        #expect(yaml("---") == nil)
    }

    @Test func everyLanguageQueryMatchesItsGrammar() {
        for language in InjectedLanguage.allCases { _ = language.query }  // an invalid one is a fatal error: see `compile`
    }
}

@MainActor
struct CodeInjectionTests {
    static let sample = """
    ---
    title: "Demo"
    format: html
    ---

    ```{python}
    #| echo: false
    @cache
    def f(a, b=1):
        \"\"\"doc\"\"\"
        return g(a) + 2.5 if a is not None else "x"  # why
    ```

    ```{r, echo=FALSE}
    f <- function(x) {
      if (x > 1) TRUE else NULL
    }
    # note
    ```

    ```yaml
    key: 'v'
    list: [1, true]
    ```

    ```swift
    let a = 1
    ```

    - item

      ```python
      def nested(): pass
      ```
    """

    func kinds(_ h: EngineHarness, _ range: NSRange? = nil) async throws -> [String] {
        let codeKinds: Set<TokenKind> = [.codeKeyword, .codeString, .codeComment, .codeConstant, .codeFunction, .codeKey]
        return h.slices(try await h.tokens(in: range).filter { codeKinds.contains($0.kind) })
    }

    @Test func pythonFencesAreHighlightedAsPython() async throws {
        let found = Set(try await kinds(try await EngineHarness(Self.sample)))
        for expected in [
            "codeKeyword:def", "codeKeyword:return", "codeKeyword:if", "codeKeyword:else", "codeKeyword:is", "codeKeyword:not",
            "codeFunction:f", "codeFunction:g", "codeFunction:@cache",
            "codeConstant:1", "codeConstant:2.5", "codeConstant:None",
            "codeString:\"x\"", "codeString:\"\"\"doc\"\"\"", "codeComment:# why", "codeComment:#| echo: false",
        ] { #expect(found.contains(expected), "missing \(expected)") }
    }

    @Test func rCellsAreHighlightedAsR() async throws {
        let found = Set(try await kinds(try await EngineHarness(Self.sample)))
        for expected in ["codeKeyword:function", "codeKeyword:if", "codeKeyword:else", "codeConstant:TRUE", "codeConstant:NULL", "codeConstant:1", "codeComment:# note"] {
            #expect(found.contains(expected), "missing \(expected)")
        }
    }

    @Test func frontMatterAndYamlFencesAreHighlightedAsYAML() async throws {
        let found = Set(try await kinds(try await EngineHarness(Self.sample)))
        for expected in ["codeKey:title", "codeString:\"Demo\"", "codeKey:format", "codeKey:key", "codeString:'v'", "codeKey:list", "codeConstant:1", "codeConstant:true"] {
            #expect(found.contains(expected), "missing \(expected)")
        }
    }

    @Test func otherLanguagesAndNestedFencesKeepTheCodeBlockColour() async throws {
        let h = try await EngineHarness(Self.sample)
        let swift = (Self.sample as NSString).range(of: "let a = 1")
        let nested = (Self.sample as NSString).range(of: "def nested(): pass")
        for range in [swift, nested] {
            let inside = try await h.tokens().filter { NSIntersectionRange($0.range, range).length > 0 && $0.kind.rawValue.hasPrefix("code") && $0.kind != .codeBlock && $0.kind != .codeFence }
            #expect(inside.isEmpty, "\(h.slices(inside))")
        }
    }

    @Test func tokensAreClippedToTheRequestedChunk() async throws {
        let h = try await EngineHarness(Self.sample)
        let ns = Self.sample as NSString
        let def = ns.range(of: "def f(a, b=1):")
        // A chunk that starts in the middle of the block, and cuts "return" in half.
        let ret = ns.range(of: "return")
        let chunk = NSRange(location: def.location + 2, length: ret.location + 3 - (def.location + 2))
        let found = try await h.tokens(in: chunk)
        let code = found.filter { $0.kind == .codeKeyword }
        #expect(!code.isEmpty)
        for token in code { #expect(NSIntersectionRange(token.range, chunk) == token.range, "token \(token) leaks out of \(chunk)") }
        #expect(h.slices(code).contains("codeKeyword:f"))  // "def" clipped at its start
        #expect(h.slices(code).contains("codeKeyword:ret"))
    }

    @Test func editingInsideACellRestylesIt() async throws {
        let h = try await EngineHarness("```{python}\nx = 1\n```\n")
        #expect(try await kinds(h).contains("codeConstant:1"))
        let x = ("```{python}\nx = 1\n```\n" as NSString).range(of: "x = 1")
        await h.replace(x, with: "if True: pass")
        let after = try await kinds(h)
        #expect(after.contains("codeKeyword:if") && after.contains("codeConstant:True") && after.contains("codeKeyword:pass"))
        #expect(!after.contains("codeConstant:1"))
    }

    @Test func aRegionOverTheLimitIsLeftPlain() async throws {
        let long = String(repeating: "x = 1\n", count: MarkdownHighlightEngine.maxInjectionLength / 6 + 10)
        let h = try await EngineHarness("```python\n\(long)```\n")
        #expect(try await kinds(h, NSRange(location: 0, length: 200)).isEmpty)
        let short = try await EngineHarness("```python\nx = 1\n```\n")
        #expect(try await kinds(short).contains("codeConstant:1"))
    }

    @Test func aFenceWithoutClosingDelimiterStillWorks() async throws {
        let h = try await EngineHarness("```python\ndef f(): pass\n")
        #expect(try await kinds(h).contains("codeKeyword:def"))
    }

    @Test func aDocumentWithoutAnyOfThisHasNoCodeTokens() async throws {
        let h = try await EngineHarness("# Title\n\ntext `code`\n\n```\nplain\n```\n")
        #expect(try await kinds(h).isEmpty)
    }

    @Test func theLanguageColoursReachTheTextStorage() async throws {
        let text = "```{python}\ndef f():\n    return 1\n```\n"
        let view = ViewTests.makeSizedView(text)
        let theme = view.theme
        let keyword = try #require(theme.tokens[.codeKeyword]?.color)
        let constant = try #require(theme.tokens[.codeConstant]?.color)
        let at = { (needle: String) in (text as NSString).range(of: needle).location }
        func color(_ i: Int) -> NSColor? { view.textStorage?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }
        #expect(await eventually { color(at("def")) == keyword })
        #expect(await eventually { color(at("1")) == constant })
        #expect(color(at("f():")) != keyword)
    }

    private func color(_ view: MarkdownTextView, _ i: Int) -> NSColor? { view.textStorage?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }

    @Test func changingTheLanguageOnTheFenceLineRestylesParagraphsAfterABlankLine() async throws {
        let text = "```python\nx = 1\n\nTRUE\n\nNULL\n```\n"
        let view = ViewTests.makeSizedView(text)
        let constant = try #require(view.theme.tokens[.codeConstant]?.color)
        let ns = text as NSString
        #expect(await eventually { color(view, ns.range(of: "1").location) == constant })  // Python's number
        #expect(color(view, ns.range(of: "NULL").location) != constant)  // a plain identifier in Python
        view.textStorage?.replaceCharacters(in: ns.range(of: "python"), with: "r")
        let edited = view.string as NSString
        #expect(await eventually { color(view, edited.range(of: "NULL").location) == constant && color(view, edited.range(of: "TRUE").location) == constant })
    }

    @Test func openingAStringInTheFirstParagraphRestylesTheRestOfTheCell() async throws {
        let text = "```python\nx = 1\n\nif y:\n    pass\n\nz = 2\n```\n"
        let view = ViewTests.makeSizedView(text)
        let keyword = try #require(view.theme.tokens[.codeKeyword]?.color)
        let ns = text as NSString
        #expect(await eventually { color(view, ns.range(of: "if").location) == keyword })
        view.textStorage?.replaceCharacters(in: ns.range(of: "1"), with: "\"\"\"")
        let edited = view.string as NSString
        // Now the string runs to the end of the cell: nothing after the blank line is a keyword any more.
        #expect(await eventually { color(view, edited.range(of: "if").location) != keyword && color(view, edited.range(of: "pass").location) != keyword })
    }

    @Test func theEngineKeepsRegionsInStepWithEdits() async throws {
        let h = try await EngineHarness("a\n\n```python\nx = 1\n```\n")
        _ = try await h.tokens()
        let region = try #require(h.engine.injectionRegions.first)
        #expect((h.text as NSString).substring(with: region.range) == "x = 1\n")
        await h.replace(NSRange(location: 0, length: 0), with: "intro\n")  // before it: shifts
        #expect((h.text as NSString).substring(with: try #require(h.engine.injectionRegions.first).range) == "x = 1\n")
        await h.replace((h.text as NSString).range(of: "1"), with: "123")  // inside it: grows
        #expect((h.text as NSString).substring(with: try #require(h.engine.injectionRegions.first).range) == "x = 123\n")
    }

    @Test func everyThemeStylesTheCodeRoles() {
        for theme in ThemeLibrary.all {
            for kind in [TokenKind.codeKeyword, .codeString, .codeComment, .codeConstant, .codeFunction, .codeKey] {
                #expect(theme.tokens[kind]?.color != nil, "\(theme.name): \(kind)")
            }
        }
    }
}
