import ExtensionAPI
import Foundation

/// The regex layer of the editor highlighting for `.qmd` (PLAN 4.3.3), on top of the Markdown grammar: executable cell
/// headers, `#|` options, `:::` div fences, shortcodes, inline cells (these run when Quarto renders, so they get the
/// same "executable" style as a cell header) and cross-references / citations.
///
/// Stateless and line by line, so it is cheap and cannot go stale; the price is that `#|` and `:::` lines are marked
/// wherever they appear, not only inside a cell or a div.
enum QuartoDecorations {
    private static let rules: [(pattern: String, token: String)] = [
        // whole-line rules first, so the inline ones paint over them
        (#"^[ \t]*`{3,}[ \t]*\{[A-Za-z][^}\n]*\}[ \t]*$"#, "quartoCell"),  // ```{python}   ```{r, echo=FALSE}
        (#"^[ \t]*(?:#|//|%%)\|.*$"#, "quartoOption"),  // #| echo: false
        (#"^[ \t]*:{3,}.*$"#, "quartoDiv"),  // :::  ::: {.callout-note}
        (#"\{\{<.*?>\}\}"#, "quartoShortcode"),
        (#"`\{[A-Za-z][\w+-]*\}[ \t][^`\n]*`|`r[ \t]+[^`\n]+`"#, "quartoCell"),  // `{python} x`  `r x`
        (#"(?<![\w@])-?@(?:fig|tbl|eq|lst|sec|thm|lem|cor|prp|cnj|def|exm|exr)-[\w.-]*\w|\[-?@[^\]\n]+\]"#, "quartoRef"),
    ]

    private static let compiled: [(regex: NSRegularExpression, token: String)] = rules.map { (try! NSRegularExpression(pattern: $0.pattern), $0.token) }

    static func spans(in lines: [Substring], firstLine: Int) -> [DecorationSpan] {
        var out: [DecorationSpan] = []
        for (i, line) in lines.enumerated() where !line.isEmpty {
            let text = String(line)
            let whole = NSRange(location: 0, length: (text as NSString).length)
            for rule in compiled {
                for match in rule.regex.matches(in: text, range: whole) where match.range.length > 0 {
                    out.append(DecorationSpan(line: firstLine + i, columns: match.range.location..<(match.range.location + match.range.length), token: rule.token))
                }
            }
        }
        return out
    }
}
