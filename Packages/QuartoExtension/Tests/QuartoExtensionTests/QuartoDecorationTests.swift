import ExtensionAPI
import Foundation
import Testing
@testable import QuartoExtension

private func spans(_ text: String, first: Int = 0) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return QuartoFlavor().editorDecorations(visibleLines: lines, firstLine: first).map { span in
        let line = lines[span.line - first]
        let units = Array(line.utf16)[span.columns]
        return "\(span.token):\(span.line):\(String(decoding: units, as: UTF16.self))"
    }
}

@Test func cellHeadersOptionsAndDivFencesAreMarkedWholeLine() {
    #expect(spans("```{python}") == ["quartoCell:0:```{python}"])
    #expect(spans("  ```{r, echo=FALSE}  ") == ["quartoCell:0:  ```{r, echo=FALSE}  "])
    #expect(spans("#| echo: false") == ["quartoOption:0:#| echo: false"])
    #expect(spans("//| output: asis") == ["quartoOption:0://| output: asis"])
    #expect(spans("::: {.callout-note}") == ["quartoDiv:0:::: {.callout-note}"])
    #expect(spans(":::") == ["quartoDiv:0::::"])
    // not Quarto syntax: plain fences, non-executable cells, comments
    #expect(spans("```python").isEmpty && spans("```{.python}").isEmpty && spans("``` {=html}").isEmpty && spans("# comment").isEmpty)
}

@Test func shortcodesInlineCellsAndCrossReferencesAreMarked() {
    #expect(spans("a {{< var x >}} b {{< pagebreak >}}") == ["quartoShortcode:0:{{< var x >}}", "quartoShortcode:0:{{< pagebreak >}}"])
    #expect(spans("mean `{python} df.x.mean()` and `r 1 + 1` but `r` and `x`") == ["quartoCell:0:`{python} df.x.mean()`", "quartoCell:0:`r 1 + 1`"])
    #expect(spans("see @fig-plot, [@doe99; @roe2000] and -@tbl-a; mail me@fig-x.com") == ["quartoRef:0:@fig-plot", "quartoRef:0:[@doe99; @roe2000]", "quartoRef:0:-@tbl-a"])
}

@Test func spansCarryDocumentLineNumbersAndUTF16Columns() {
    let found = QuartoFlavor().editorDecorations(visibleLines: ["中文 😀 {{< var x >}}", "", "::: x"], firstLine: 40)
    #expect(found == [
        DecorationSpan(line: 40, columns: 6..<19, token: "quartoShortcode"),  // "中文 " = 3 units, the emoji is 2, then a space
        DecorationSpan(line: 42, columns: 0..<5, token: "quartoDiv"),
    ])
}

@Test func decorationsAreCheapOnAHugeVisibleBlock() {
    let lines = (0..<2_000).map { Substring($0 % 3 == 0 ? "::: {.callout-note}" : "plain text with `code` and a link [x](y)") }
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = QuartoFlavor().editorDecorations(visibleLines: lines, firstLine: 0) }
    #expect(elapsed < .seconds(1))  // loose: a screenful is ~60 lines; this only catches a pathological regex
}
