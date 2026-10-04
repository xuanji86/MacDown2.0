import Foundation
import Testing
@testable import MarkdownCore

@Suite struct TaskToggleTests {
    /// Applies the edit like the editor would (UTF-16 range), nil when there is none.
    private func toggled(_ text: String, line: Int, checked: Bool) -> String? {
        guard let edit = TaskToggle.edit(in: text, line: line, checked: checked) else { return nil }
        #expect(edit.range.length == 1)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: Every item form

    @Test(arguments: [
        ("- [ ] a", "- [x] a"),
        ("* [ ] a", "* [x] a"),
        ("+ [ ] a", "+ [x] a"),
        ("1. [ ] a", "1. [x] a"),
        ("12) [ ] a", "12) [x] a"),
        ("-   [ ] a", "-   [x] a"),
        ("  - [ ] nested", "  - [x] nested"),
        ("        - [ ] deeply nested", "        - [x] deeply nested"),
        ("\t- [ ] tab indented", "\t- [x] tab indented"),
        ("> - [ ] in a quote", "> - [x] in a quote"),
        (">- [ ] tight quote", ">- [x] tight quote"),
        ("> > 1. [ ] two quotes", "> > 1. [x] two quotes"),
        ("- - [ ] list in a list", "- - [x] list in a list"),
        ("- [\u{a0}] no-break space mark", "- [x] no-break space mark"),
        ("- [ ]\u{a0}no-break space after", "- [x]\u{a0}no-break space after"),
        ("- [ ] 中文 😀 text", "- [x] 中文 😀 text"),
    ])
    func checksAnOpenItem(_ source: String, _ expected: String) {
        #expect(toggled(source, line: 0, checked: true) == expected)
        #expect(TaskToggle.edit(in: source, line: 0, checked: false) == nil)  // already open
    }

    @Test(arguments: [
        ("- [x] a", "- [ ] a"),
        ("- [X] a", "- [ ] a"),
        ("1. [X] a", "1. [ ] a"),
        ("  * [x] nested", "  * [ ] nested"),
        ("> + [x] quoted", "> + [ ] quoted"),
    ])
    func unchecksADoneItem(_ source: String, _ expected: String) {
        #expect(toggled(source, line: 0, checked: false) == expected)
        #expect(TaskToggle.edit(in: source, line: 0, checked: true) == nil)  // already done
    }

    @Test func editIsTheOneMarkCharacterAndNothingElse() throws {
        let text = "intro\n\n- [ ] one\n- [X] 二\n"
        let open = try #require(TaskToggle.edit(in: text, line: 2, checked: true))
        #expect(open == TaskToggle.Edit(range: NSRange(location: 10, length: 1), replacement: "x"))
        let done = try #require(TaskToggle.edit(in: text, line: 3, checked: false))
        #expect(done == TaskToggle.Edit(range: NSRange(location: 20, length: 1), replacement: " "))
    }

    @Test func offsetsAreUTF16UnitsAfterWideCharacters() throws {
        let text = "😀 emoji line\n中文\n- [ ] after\n"  // the emoji is two UTF-16 units
        let edit = try #require(TaskToggle.edit(in: text, line: 2, checked: true))
        #expect((text as NSString).substring(with: edit.range) == " ")
        #expect(edit.range.location == (text as NSString).range(of: "[ ]").location + 1)
    }

    @Test func picksTheRequestedLineAmongSeveralItems() {
        let text = "- [ ] a\n- [x] b\n  - [ ] c\n- [ ] d"
        #expect(toggled(text, line: 0, checked: true) == "- [x] a\n- [x] b\n  - [ ] c\n- [ ] d")
        #expect(toggled(text, line: 1, checked: false) == "- [ ] a\n- [ ] b\n  - [ ] c\n- [ ] d")
        #expect(toggled(text, line: 2, checked: true) == "- [ ] a\n- [x] b\n  - [x] c\n- [ ] d")
        #expect(toggled(text, line: 3, checked: true) == "- [ ] a\n- [x] b\n  - [ ] c\n- [x] d")  // last line, no trailing newline
    }

    // MARK: Lines that are not task items

    @Test(arguments: [
        "- [] empty brackets",
        "- [y] other mark",
        "- [xx] two marks",
        "-[ ] no space after the marker",
        "- [ ]no space after the bracket",
        "- [ ]\ttab after the bracket",
        "- [ ]",
        "- [ ] ",
        "- [ ]   ",
        "[ ] no list marker",
        "text - [ ] after text",
        "1.[ ] glued",
        "1234567890. [ ] ten digits",
        "a. [ ] letter marker",
        "- - -",
        "    ",
        "",
        "# - [ ] heading",
        "| - [ ] | table |",
    ])
    func refusesAnythingThatIsNotATaskItem(_ source: String) {
        #expect(TaskToggle.edit(in: source, line: 0, checked: true) == nil)
        #expect(TaskToggle.edit(in: source, line: 0, checked: false) == nil)
    }

    @Test func aLineThatStoppedBeingATaskIsRefused() {
        // The page asked for line 1 of an older text; the current one has the item elsewhere.
        #expect(TaskToggle.edit(in: "- [ ] a\n\nplain\n", line: 2, checked: true) == nil)
        #expect(TaskToggle.edit(in: "x\n- [ ] a\n", line: 0, checked: true) == nil)
    }

    @Test func outOfRangeLinesAreRefused() {
        #expect(TaskToggle.edit(in: "- [ ] a\n", line: -1, checked: true) == nil)
        #expect(TaskToggle.edit(in: "- [ ] a\n", line: 2, checked: true) == nil)  // the empty line after the final \n is line 1
        #expect(TaskToggle.edit(in: "- [ ] a\n", line: 1, checked: true) == nil)
        #expect(TaskToggle.edit(in: "- [ ] a", line: 1, checked: true) == nil)
        #expect(TaskToggle.edit(in: "", line: 0, checked: true) == nil)
        #expect(TaskToggle.edit(in: "- [ ] a", line: Int.max, checked: true) == nil)
    }

    // MARK: Fenced code, front matter

    @Test func aTaskLookingLineInsideAFenceIsLeftAlone() {
        for fence in ["```", "~~~", "````", "```swift"] {
            let close = fence.hasPrefix("~") ? "~~~" : fence.hasPrefix("````") ? "````" : "```"
            let text = "\(fence)\n- [ ] not a task\n- [x] nor this\n\(close)\n- [ ] real\n"
            #expect(TaskToggle.edit(in: text, line: 1, checked: true) == nil, "\(fence)")
            #expect(TaskToggle.edit(in: text, line: 2, checked: false) == nil, "\(fence)")
            #expect(toggled(text, line: 4, checked: true)?.hasSuffix("- [x] real\n") == true, "\(fence) closes")
        }
    }

    @Test func fenceRules() {
        // a shorter or different closer does not end the fence; ``` inside ~~~ is just text
        #expect(TaskToggle.edit(in: "````\n```\n- [ ] a\n````\n", line: 2, checked: true) == nil)
        #expect(TaskToggle.edit(in: "~~~\n```\n- [ ] a\n~~~\n", line: 2, checked: true) == nil)
        // a closer carries no text; a fence line with text after it is content
        #expect(TaskToggle.edit(in: "```\n``` not a closer\n- [ ] a\n```\n", line: 2, checked: true) == nil)
        // an unclosed fence runs to the end of the document
        #expect(TaskToggle.edit(in: "```\n- [ ] a\n", line: 1, checked: true) == nil)
        // a backtick fence cannot have a backtick in its info string: that line is a code span, not a fence
        #expect(toggled("```a`b\n- [ ] a\n", line: 1, checked: true) == "```a`b\n- [x] a\n")
        // inline triple backticks mid-line open nothing
        #expect(toggled("text ``` more\n- [ ] a\n", line: 1, checked: true) == "text ``` more\n- [x] a\n")
        // a fence inside a quote or a list item is a fence too
        #expect(TaskToggle.edit(in: "> ```\n> - [ ] a\n> ```\n", line: 1, checked: true) == nil)
        #expect(TaskToggle.edit(in: "- ```\n  - [ ] a\n  ```\n", line: 1, checked: true) == nil)
        #expect(toggled("> ```\n> x\n> ```\n- [ ] a\n", line: 3, checked: true) == "> ```\n> x\n> ```\n- [x] a\n")
        // a task item after two separate fences
        #expect(toggled("```\na\n```\n\n```\nb\n```\n- [ ] z\n", line: 7, checked: true) == "```\na\n```\n\n```\nb\n```\n- [x] z\n")
    }

    @Test func frontMatterIsNotMarkdown() {
        #expect(TaskToggle.edit(in: "---\n- [ ] a\n---\n- [ ] b\n", line: 1, checked: true) == nil)
        #expect(toggled("---\n- [ ] a\n---\n- [ ] b\n", line: 3, checked: true) == "---\n- [ ] a\n---\n- [x] b\n")
        #expect(TaskToggle.edit(in: "+++\n- [ ] a\n+++\n", line: 1, checked: true) == nil)
        #expect(TaskToggle.edit(in: "---\n- [ ] a\n...\n", line: 1, checked: true) == nil)
        // a first line that is not a front matter opener, or one that never closes, is plain text
        #expect(toggled("- [ ] a\n---\n", line: 0, checked: true) == "- [x] a\n---\n")
        #expect(toggled("---\n- [ ] a\n", line: 1, checked: true) == "---\n- [x] a\n")
    }

    // MARK: Parity with the renderer

    /// The lines the renderer gives a checkbox (`data-line` of the element holding it) are exactly the lines this type accepts, over
    /// every item form, a fence, front matter and look-alikes. Keeps the marker grammar in step with `@mdit/plugin-tasklist`.
    @Test func acceptsExactlyTheLinesTheRendererMakesCheckboxesOf() async throws {
        let source = """
        ---
        - [ ] front matter, not a task
        ---

        - [ ] a
        - [x] b
          - [X] nested
        \t- [ ] tab nested
        * [ ] star
        + [x] plus
        1. [ ] ordered
        2) [x] paren
        -   [ ] wide marker

        > - [ ] quoted
        > > 1. [x] twice

        - - [ ] list in a list
        - [] empty
        - [y] other
        -[ ] glued
        - [ ]no space
        - [ ]
        [ ] no marker
        - [\u{a0}] nbsp mark
        - [ ]\u{a0}nbsp after

        ```
        - [ ] fenced
        ```

        ~~~
        - [x] tilde fenced
        ~~~

        - [ ] loose item

          second paragraph
        - [ ] last
        """
        let html = try await JSCRenderer().render(source, options: RenderOptions()).html
        let rendered = Set(html.matches(of: /data-line="(\d+)"[^>]*><input type="checkbox" class="task-list-item-checkbox"/).map { Int($0.1)! })
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let accepted = Set(lines.indices.filter {
            TaskToggle.edit(in: source, line: $0, checked: true) != nil || TaskToggle.edit(in: source, line: $0, checked: false) != nil
        })
        #expect(!rendered.isEmpty)
        #expect(accepted == rendered, "accepted \(accepted.sorted()) but the page has checkboxes on \(rendered.sorted())")
    }

    // MARK: The file on disk

    /// Decodes `data` as a file would be opened, applies the toggle to the LF text, writes it back.
    private func saved(_ data: Data, as encoding: TextEncoding? = nil, line: Int, checked: Bool) throws -> Data {
        var file = try encoding.map { try MarkdownFile.decode(data, as: $0) } ?? MarkdownFile.decode(data)
        let edit = try #require(TaskToggle.edit(in: file.text, line: line, checked: checked))
        file.text = (file.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return try file.encoded()
    }

    @Test func crlfFileKeepsItsLineEndingsAndOtherBytes() throws {
        let before = Data("# T\r\n\r\n- [ ] a\r\n- [x] b\r\n".utf8)
        #expect(try saved(before, line: 2, checked: true) == Data("# T\r\n\r\n- [x] a\r\n- [x] b\r\n".utf8))
        #expect(try saved(before, line: 3, checked: false) == Data("# T\r\n\r\n- [ ] a\r\n- [ ] b\r\n".utf8))
    }

    @Test func bareCRFileKeepsItsLineEndings() throws {
        let before = Data("- [ ] a\r- [x] b\r".utf8)
        #expect(try saved(before, line: 0, checked: true) == Data("- [x] a\r- [x] b\r".utf8))
    }

    @Test func utf8WithBOMKeepsItsBOM() throws {
        let before = Data([0xEF, 0xBB, 0xBF] + Array("- [ ] 中\n".utf8))
        #expect(try saved(before, line: 0, checked: true) == Data([0xEF, 0xBB, 0xBF] + Array("- [x] 中\n".utf8)))
    }

    @Test(arguments: [TextEncoding.utf16LE, .utf16BE, .gb18030, .shiftJIS, .windows1252, .macRoman])
    func otherEncodingsChangeExactlyOneUnit(encoding: TextEncoding) throws {
        let text = encoding == .gb18030 ? "标题\n- [ ] 任务\n" : encoding == .shiftJIS ? "見出し\n- [ ] タスク\n" : "café\n- [ ] tâche\n"
        let open = try MarkdownFile(text: text, lineEnding: .crlf, encoding: encoding, hasBOM: encoding == .utf16LE || encoding == .utf16BE).encoded()
        let done = try MarkdownFile(text: text.replacingOccurrences(of: "[ ]", with: "[x]"), lineEnding: .crlf, encoding: encoding, hasBOM: encoding == .utf16LE || encoding == .utf16BE).encoded()
        #expect(open.count == done.count)
        #expect(zip(open, done).filter { $0 != $1 }.count == 1)  // one byte: ' ' (0x20) became 'x' (0x78), in either UTF-16 order
        #expect(try saved(open, as: encoding, line: 1, checked: true) == done)
        #expect(try saved(done, as: encoding, line: 1, checked: false) == open)
    }
}
