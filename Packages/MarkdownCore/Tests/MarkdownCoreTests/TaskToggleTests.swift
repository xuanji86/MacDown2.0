import Foundation
import Testing
@testable import MarkdownCore

/// Which lines are task items is decided by the renderer (`RenderResult.tasks`), `TaskToggle` only finds the mark on the line the
/// renderer named. So these tests go through the real renderer: whatever it calls a checkbox must toggle, nothing else may.
@Suite struct TaskToggleTests {
    private let renderer = try! JSCRenderer()  // lazy: one JavaScriptCore context per test is plenty

    private func tasks(_ text: String, _ options: RenderOptions = RenderOptions()) async throws -> [TaskItem] {
        try await renderer.render(text, options: options).tasks
    }

    /// Applies the edit like the editor would (UTF-16 range); nil when the renderer sees no checkbox there or there is nothing to do.
    private func toggled(_ text: String, line: Int, checked: Bool, _ options: RenderOptions = RenderOptions()) async throws -> String? {
        guard let task = try await tasks(text, options).first(where: { $0.line == line }),
              let edit = TaskToggle.edit(in: text, task: task, checked: checked) else { return nil }
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
        ("> - [ ] in a quote", "> - [x] in a quote"),
        (">- [ ] tight quote", ">- [x] tight quote"),
        ("> > 1. [ ] two quotes", "> > 1. [x] two quotes"),
        ("- - [ ] list in a list", "- - [x] list in a list"),
        ("- [\u{a0}] no-break space mark", "- [x] no-break space mark"),
        ("- [ ]\u{a0}no-break space after", "- [x]\u{a0}no-break space after"),
        ("- [ ] 中文 😀 text", "- [x] 中文 😀 text"),
    ])
    func checksAnOpenItem(_ source: String, _ expected: String) async throws {
        #expect(try await toggled(source, line: 0, checked: true) == expected)
        #expect(try await toggled(source, line: 0, checked: false) == nil)  // already open
    }

    @Test func indentationIsTheRenderersCall() async throws {
        #expect(try await toggled("- parent\n  - child\n        - [ ] deep\n", line: 2, checked: true) == nil)  // 8 spaces under a 4-space item: code
        #expect(try await toggled("- parent\n    - [ ] four\n", line: 1, checked: true) == "- parent\n    - [x] four\n")
        #expect(try await toggled("- parent\n\t- [ ] tab\n", line: 1, checked: true) == "- parent\n\t- [x] tab\n")
        #expect(try await toggled("    - [ ] code\n", line: 0, checked: true) == nil)
    }

    @Test(arguments: [
        ("- [x] a", "- [ ] a"),
        ("- [X] a", "- [ ] a"),
        ("1. [X] a", "1. [ ] a"),
        ("  * [x] nested", "  * [ ] nested"),
        ("> + [x] quoted", "> + [ ] quoted"),
    ])
    func unchecksADoneItem(_ source: String, _ expected: String) async throws {
        #expect(try await toggled(source, line: 0, checked: false) == expected)
        #expect(try await toggled(source, line: 0, checked: true) == nil)  // already done
    }

    @Test func editIsTheOneMarkCharacterAndNothingElse() async throws {
        let text = "intro\n\n- [ ] one\n- [X] 二\n"
        let items = try await tasks(text)
        #expect(items == [TaskItem(line: 2, mark: 2), TaskItem(line: 3, mark: 3)])
        #expect(TaskToggle.edit(in: text, task: items[0], checked: true) == TaskToggle.Edit(range: NSRange(location: 10, length: 1), replacement: "x"))
        #expect(TaskToggle.edit(in: text, task: items[1], checked: false) == TaskToggle.Edit(range: NSRange(location: 20, length: 1), replacement: " "))
    }

    @Test func offsetsAreUTF16UnitsAfterWideCharacters() async throws {
        let text = "😀 emoji line\n中文\n- [ ] after\n"  // the emoji is two UTF-16 units
        let task = try #require(try await tasks(text).first)
        let edit = try #require(TaskToggle.edit(in: text, task: task, checked: true))
        #expect((text as NSString).substring(with: edit.range) == " ")
        #expect(edit.range.location == (text as NSString).range(of: "[ ]").location + 1)
    }

    @Test func picksTheRequestedItemAmongSeveral() async throws {
        let text = "- [ ] a\n- [x] b\n  - [ ] c\n- [ ] d"
        #expect(try await toggled(text, line: 0, checked: true) == "- [x] a\n- [x] b\n  - [ ] c\n- [ ] d")
        #expect(try await toggled(text, line: 1, checked: false) == "- [ ] a\n- [ ] b\n  - [ ] c\n- [ ] d")
        #expect(try await toggled(text, line: 2, checked: true) == "- [ ] a\n- [x] b\n  - [x] c\n- [ ] d")
        #expect(try await toggled(text, line: 3, checked: true) == "- [ ] a\n- [x] b\n  - [ ] c\n- [x] d")  // last line, no trailing newline
    }

    // MARK: Lines the renderer does not make checkboxes of

    @Test(arguments: [
        "- [] empty brackets",
        "- [y] other mark",
        "- [xx] two marks",
        "-[ ] no space after the marker",
        "- [ ]no space after the bracket",
        "- [ ]\ttab after the bracket",
        "- [ ]",
        "- [ ] ",
        "[ ] no list marker",
        "text - [ ] after text",
        "1.[ ] glued",
        "1234567890. [ ] ten digits",
        "a. [ ] letter marker",
        "- - -",
        "",
        "# - [ ] heading",
        "| - [ ] | table |",
        "    - [ ] indented code",
        "<div>\n- [ ] inside an html block\n</div>",
        "$$\n- [ ] inside math\n$$",
    ])
    func refusesAnythingThatIsNotATaskItem(_ source: String) async throws {
        for line in 0..<source.split(separator: "\n", omittingEmptySubsequences: false).count {
            #expect(try await toggled(source, line: line, checked: true) == nil)
            #expect(try await toggled(source, line: line, checked: false) == nil)
        }
    }

    @Test func aTextThatMovedOnHasNoSuchTask() async throws {
        // The renderer's task list belongs to the text it rendered; against another text the line is not a task any more.
        let task = try #require(try await tasks("- [ ] a\n").first)
        #expect(TaskToggle.edit(in: "plain\n", task: task, checked: true) == nil)
        #expect(TaskToggle.edit(in: "x\n- [ ] a\n", task: task, checked: true) == nil)
        #expect(TaskToggle.edit(in: "- [ ] a\n", task: TaskItem(line: 5, mark: 5), checked: true) == nil)  // beyond the text
        #expect(TaskToggle.edit(in: "- [ ] a\n", task: TaskItem(line: -1, mark: -1), checked: true) == nil)
        #expect(TaskToggle.edit(in: "- [ ] a", task: TaskItem(line: 1, mark: 1), checked: true) == nil)
    }

    // MARK: What the renderer decides (fences, front matter, options): no second parser to disagree

    @Test func aTaskLookingLineInsideAFenceIsLeftAlone() async throws {
        for fence in ["```", "~~~", "````", "```swift"] {
            let close = fence.hasPrefix("~") ? "~~~" : fence.hasPrefix("````") ? "````" : "```"
            let text = "\(fence)\n- [ ] not a task\n- [x] nor this\n\(close)\n- [ ] real\n"
            #expect(try await toggled(text, line: 1, checked: true) == nil, "\(fence)")
            #expect(try await toggled(text, line: 2, checked: false) == nil, "\(fence)")
            #expect(try await toggled(text, line: 4, checked: true)?.hasSuffix("- [x] real\n") == true, "\(fence) closes")
        }
    }

    @Test func aFenceThatClosesInsideAListItemDoesNotHideLaterItems() async throws {
        let text = "- ~~~\n    code\n    ~~~\n\n- [ ] real\n"
        #expect(try await toggled(text, line: 4, checked: true) == "- ~~~\n    code\n    ~~~\n\n- [x] real\n")
        let quote = "> ```\n> - [ ] in the fence\n> ```\n\n- [ ] after\n"
        #expect(try await toggled(quote, line: 1, checked: true) == nil)
        #expect(try await toggled(quote, line: 4, checked: true) == "> ```\n> - [ ] in the fence\n> ```\n\n- [x] after\n")
    }

    @Test func aMarkerLineWhoseTextContinuesBelowIsATask() async throws {
        #expect(try await toggled("- [ ] \n  continuation\n", line: 0, checked: true) == "- [x] \n  continuation\n")
        // the item that starts with an empty bullet line: the page reports the item's line, the mark is on the next one
        let text = "-\n  [ ] later\n"
        let task = try #require(try await tasks(text).first)
        #expect(task == TaskItem(line: 0, mark: 1))
        #expect(try await toggled(text, line: 0, checked: true) == "-\n  [x] later\n")
    }

    @Test func frontMatterFollowsTheRenderOptions() async throws {
        let yaml = "---\n- [ ] in front matter\n---\n- [ ] after\n"
        #expect(try await toggled(yaml, line: 1, checked: true) == nil)  // front matter on (default): metadata
        #expect(try await toggled(yaml, line: 3, checked: true) == "---\n- [ ] in front matter\n---\n- [x] after\n")
        var off = RenderOptions()
        off.extensions.remove(.frontMatter)
        #expect(try await toggled(yaml, line: 1, checked: true, off) == "---\n- [x] in front matter\n---\n- [ ] after\n")  // two rules and a list
        let toml = "+++\n- [ ] in toml\n+++\n"
        #expect(try await toggled(toml, line: 1, checked: true) == nil)
        #expect(try await toggled(toml, line: 1, checked: true, off) == "+++\n- [x] in toml\n+++\n")  // Hugo front matter is the same option
    }

    @Test func switchingTaskListsOffLeavesNothingToToggle() async throws {
        var off = RenderOptions()
        off.extensions.remove(.taskLists)
        #expect(try await tasks("- [ ] a\n", off).isEmpty)
    }

    /// Toggling every task the renderer found, one at a time, flips exactly that checkbox in the next render and nothing else, over
    /// a document that has every awkward shape the renderer knows.
    @Test func everyRendererTaskTogglesAndOnlyThatOne() async throws {
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

        - ~~~
            code
            ~~~

        - [ ] after a fence closed in a list item

        - [ ] loose item

          second paragraph
        - [ ] last
        - [ ] 
          continuation
        -
          [ ] marker below the bullet
        """
        func states(_ html: String) -> [Bool] {
            html.matches(of: /<input[^>]*task-list-item-checkbox[^>]*>/).map { $0.output.contains("checked=\"checked\"") }
        }
        let first = try await renderer.render(source, options: RenderOptions())
        let before = states(first.html)
        #expect(first.tasks.count == before.count)
        #expect(before.count > 15)
        for (i, task) in first.tasks.enumerated() {
            let edit = try #require(TaskToggle.edit(in: source, task: task, checked: !before[i]), "task \(i) at line \(task.line)")
            #expect(TaskToggle.edit(in: source, task: task, checked: before[i]) == nil)
            let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let after = states(try await renderer.render(changed, options: RenderOptions()).html)
            var expected = before
            expected[i].toggle()
            #expect(after == expected, "toggling task \(i) at line \(task.line) changed something else")
        }
    }

    // MARK: The file on disk

    /// Decodes `data` as a file would be opened, applies the toggle to the LF text, writes it back.
    private func saved(_ data: Data, as encoding: TextEncoding? = nil, line: Int, checked: Bool) async throws -> Data {
        var file = try encoding.map { try MarkdownFile.decode(data, as: $0) } ?? MarkdownFile.decode(data)
        let task = try #require(try await tasks(file.text).first(where: { $0.line == line }))
        let edit = try #require(TaskToggle.edit(in: file.text, task: task, checked: checked))
        file.text = (file.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return try file.encoded()
    }

    @Test func crlfFileKeepsItsLineEndingsAndOtherBytes() async throws {
        let before = Data("# T\r\n\r\n- [ ] a\r\n- [x] b\r\n".utf8)
        #expect(try await saved(before, line: 2, checked: true) == Data("# T\r\n\r\n- [x] a\r\n- [x] b\r\n".utf8))
        #expect(try await saved(before, line: 3, checked: false) == Data("# T\r\n\r\n- [ ] a\r\n- [ ] b\r\n".utf8))
    }

    @Test func bareCRFileKeepsItsLineEndings() async throws {
        let before = Data("- [ ] a\r- [x] b\r".utf8)
        #expect(try await saved(before, line: 0, checked: true) == Data("- [x] a\r- [x] b\r".utf8))
    }

    @Test func utf8WithBOMKeepsItsBOM() async throws {
        let before = Data([0xEF, 0xBB, 0xBF] + Array("- [ ] 中\n".utf8))
        #expect(try await saved(before, line: 0, checked: true) == Data([0xEF, 0xBB, 0xBF] + Array("- [x] 中\n".utf8)))
    }

    @Test(arguments: [TextEncoding.utf16LE, .utf16BE, .gb18030, .shiftJIS, .windows1252, .macRoman])
    func otherEncodingsChangeExactlyOneUnit(encoding: TextEncoding) async throws {
        let text = encoding == .gb18030 ? "标题\n- [ ] 任务\n" : encoding == .shiftJIS ? "見出し\n- [ ] タスク\n" : "café\n- [ ] tâche\n"
        let bom = encoding == .utf16LE || encoding == .utf16BE
        let open = try MarkdownFile(text: text, lineEnding: .crlf, encoding: encoding, hasBOM: bom).encoded()
        let done = try MarkdownFile(text: text.replacingOccurrences(of: "[ ]", with: "[x]"), lineEnding: .crlf, encoding: encoding, hasBOM: bom).encoded()
        #expect(open.count == done.count)
        #expect(zip(open, done).filter { $0 != $1 }.count == 1)  // one byte: ' ' (0x20) became 'x' (0x78), in either UTF-16 order
        #expect(try await saved(open, as: encoding, line: 1, checked: true) == done)
        #expect(try await saved(done, as: encoding, line: 1, checked: false) == open)
    }
}
