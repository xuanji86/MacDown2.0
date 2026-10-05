import Foundation
import SwiftTreeSitter
import TreeSitterPython
import TreeSitterR
import TreeSitterYAML

/// The languages the Markdown block grammar hands regions to (PLAN 4.3.2): fenced code and YAML front matter. Python and R are
/// Quarto's two executable languages (` ```{python} `, ` ```{r} `), YAML is the front matter and ` ```yaml ` fences. Everything
/// else stays one colour (`codeBlock`).
///
/// Injection is done by hand rather than with SwiftTreeSitterLayer: the block query names the regions (`Grammar.inject*Capture`),
/// the engine parses each one as a document of its own and maps the captures back. Each grammar's queries below are our own, small
/// and mapped to the six `code*` roles every theme styles (the grammars' own `highlights.scm` use editor-specific capture names and
/// predicates).
///
/// lazy: a region is parsed whole, and not at all above `MarkdownHighlightEngine.maxInjectionLength`; no incremental re-parse of a
/// region (the last few results are cached by text, so scrolling through one block parses it once); Quarto `#|` option lines are
/// styled by the flavor's overlay, not as YAML.
enum InjectedLanguage: CaseIterable, Hashable, Sendable {
    case python, r, yaml

    /// The language an info string asks for: `python`, `py`, `{python}`, `{r, echo=FALSE}`, `{.python .numberLines}`, `yaml`, `yml`.
    /// Case-insensitive; anything else (including no language) is nil.
    static func named(infoString: String) -> InjectedLanguage? {
        var s = Substring(infoString.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("{") {  // Quarto: an executable cell, or `{.python}` for plain code
            s = s.dropFirst()
            if s.hasPrefix(".") { s = s.dropFirst() }
        }
        let word = s.prefix { !$0.isWhitespace && $0 != "," && $0 != "}" && $0 != "{" }
        switch word.lowercased() {
        case "python", "py", "python3": return .python
        case "r": return .r
        case "yaml", "yml": return .yaml
        default: return nil
        }
    }

    /// The part of a `---` front matter block (as tree-sitter-markdown reports it, delimiters included) that is YAML: the lines
    /// between the delimiters, as a range inside `block`. Nil when there is nothing between them.
    static func yamlRange(ofFrontMatter block: NSString) -> NSRange? {
        let first = block.lineRange(for: NSRange(location: 0, length: 0))
        guard first.length < block.length else { return nil }
        var end = block.length
        let last = block.lineRange(for: NSRange(location: block.length - 1, length: 0))
        if last.location > first.location {
            let line = block.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." { end = last.location }
        }
        return end > NSMaxRange(first) ? NSRange(location: NSMaxRange(first), length: end - NSMaxRange(first)) : nil
    }

    var grammar: Language {
        switch self {
        case .python: Self.pythonGrammar
        case .r: Self.rGrammar
        case .yaml: Self.yamlGrammar
        }
    }

    var query: Query {
        switch self {
        case .python: Self.pythonQuery
        case .r: Self.rQuery
        case .yaml: Self.yamlQuery
        }
    }

    private static let pythonGrammar = Language(tree_sitter_python())
    private static let rGrammar = Language(tree_sitter_r())
    private static let yamlGrammar = Language(tree_sitter_yaml())

    private static let pythonQuery = compile(pythonGrammar, """
        (comment) @codeComment
        (string) @codeString
        [(integer) (float) (true) (false) (none)] @codeConstant
        (decorator) @codeFunction
        (function_definition name: (identifier) @codeFunction)
        (class_definition name: (identifier) @codeFunction)
        (call function: (identifier) @codeFunction)
        (call function: (attribute attribute: (identifier) @codeFunction))
        ["and" "as" "assert" "async" "await" "break" "class" "continue" "def" "del" "elif" "else" "except" "finally" "for" "from"
         "global" "if" "import" "in" "is" "lambda" "nonlocal" "not" "or" "pass" "raise" "return" "try" "while" "with" "yield"] @codeKeyword
        """)

    private static let rQuery = compile(rGrammar, """
        (comment) @codeComment
        (string) @codeString
        [(integer) (float) (complex) (true) (false) (null) (na) (inf) (nan)] @codeConstant
        (call function: (identifier) @codeFunction)
        (call function: (namespace_operator rhs: (identifier) @codeFunction))
        ["function" "if" "else" "for" "while" "repeat" "in"] @codeKeyword
        [(break) (next)] @codeKeyword
        """)

    private static let yamlQuery = compile(yamlGrammar, """
        (comment) @codeComment
        (block_mapping_pair key: (_) @codeKey)
        (flow_pair key: (_) @codeKey)
        [(double_quote_scalar) (single_quote_scalar) (block_scalar)] @codeString
        [(integer_scalar) (float_scalar) (boolean_scalar) (null_scalar)] @codeConstant
        [(anchor) (alias) (tag)] @codeFunction
        """)

    /// A query that does not match its grammar is a build problem, caught by the tests that run every query (shipped in the binary).
    private static func compile(_ grammar: Language, _ source: String) -> Query {
        do { return try Query(language: grammar, data: Data(source.utf8)) } catch { fatalError("injected-language query is invalid: \(error)") }
    }
}

/// A region of the document another grammar styles: `range` is the code itself, in document coordinates.
struct InjectionRegion: Equatable {
    var language: InjectedLanguage
    var range: NSRange
}
