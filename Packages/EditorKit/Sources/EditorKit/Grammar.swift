import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// Semantic token names (PLAN 4.5). Query capture names are these raw values.
public enum TokenKind: String, CaseIterable, Sendable {
    case heading, headingMarker
    /// Whole heading line per level (ATX or setext): carries only size/weight (`fontScale`, `bold`), so a theme can scale
    /// H1..H6 differently; colour stays with `heading` / `headingMarker`. Themes that do not mention them are unaffected.
    case heading1, heading2, heading3, heading4, heading5, heading6
    case emphasis, strong, strikethrough
    case code, codeBlock, codeFence
    case link, linkURL, linkLabel, image
    case quote, quoteMarker
    case listMarker, taskMarker
    case hr, html, frontMatter, math, escape, delimiter
    case tableHeader, tableDelimiter
    /// Only a document flavor's overlay produces these (PLAN 4.3.3, Quarto): executable cells, `#|` options, `:::` div
    /// fences, `{{< shortcodes >}}`, `@fig-x` / `[@cite]`.
    case quartoCell, quartoOption, quartoDiv, quartoShortcode, quartoRef
    /// Inside fenced code / front matter in a language the editor knows (`InjectedLanguage`): the few roles every theme styles.
    case codeKeyword, codeString, codeComment, codeConstant, codeFunction, codeKey
}

/// Compiled once. Our own capture names (instead of the grammar's nvim-style highlights.scm) because the shipped
/// queries do not cover strikethrough, tables, task lists or front matter.
enum Grammar {
    static let block = Language(tree_sitter_markdown())
    static let inline = Language(tree_sitter_markdown_inline())

    /// Capture "inline" is not a style: it marks the ranges the inline grammar must be run over.
    static let inlineCapture = "inline"

    /// Captures that name a region to run another grammar over (`InjectedLanguage`), not styles: the front matter block, and a
    /// fenced block's info string with its content. lazy: only fences directly in a section; one inside a list item or a block
    /// quote has line prefixes in its content that the other grammar would choke on.
    static let injectYAMLCapture = "injectYAML"
    static let injectInfoCapture = "injectInfo"
    static let injectContentCapture = "injectContent"

    static let blockQuery: Query = {
        let source = """
        (atx_heading (inline) @heading)
        (setext_heading (paragraph) @heading)
        (atx_heading (atx_h1_marker)) @heading1
        (atx_heading (atx_h2_marker)) @heading2
        (atx_heading (atx_h3_marker)) @heading3
        (atx_heading (atx_h4_marker)) @heading4
        (atx_heading (atx_h5_marker)) @heading5
        (atx_heading (atx_h6_marker)) @heading6
        (setext_heading (setext_h1_underline)) @heading1
        (setext_heading (setext_h2_underline)) @heading2
        [(atx_h1_marker) (atx_h2_marker) (atx_h3_marker) (atx_h4_marker) (atx_h5_marker) (atx_h6_marker)
         (setext_h1_underline) (setext_h2_underline)] @headingMarker
        (block_quote) @quote
        [(block_quote_marker) (block_continuation)] @quoteMarker
        [(fenced_code_block) (indented_code_block)] @codeBlock
        [(fenced_code_block_delimiter) (info_string)] @codeFence
        [(list_marker_plus) (list_marker_minus) (list_marker_star) (list_marker_dot) (list_marker_parenthesis)] @listMarker
        [(task_list_marker_checked) (task_list_marker_unchecked)] @taskMarker
        (thematic_break) @hr
        (html_block) @html
        [(minus_metadata) (plus_metadata)] @frontMatter
        (pipe_table_header) @tableHeader
        (pipe_table_delimiter_row) @tableDelimiter
        (link_reference_definition (link_label) @linkLabel)
        (link_reference_definition (link_destination) @linkURL)
        (backslash_escape) @escape
        (inline) @inline
        (minus_metadata) @\(Grammar.injectYAMLCapture)
        (section (fenced_code_block (info_string) @\(Grammar.injectInfoCapture) (code_fence_content) @\(Grammar.injectContentCapture)))
        """
        return try! Query(language: block, data: Data(source.utf8))
    }()

    static let inlineQuery: Query = {
        let source = """
        (emphasis) @emphasis
        (strong_emphasis) @strong
        (strikethrough) @strikethrough
        (code_span) @code
        [(emphasis_delimiter) (code_span_delimiter) (latex_span_delimiter)] @delimiter
        (inline_link (link_text) @link)
        (full_reference_link (link_text) @link)
        (collapsed_reference_link (link_text) @link)
        (shortcut_link (link_text) @link)
        (image (image_description) @image)
        [(link_destination) (uri_autolink) (email_autolink)] @linkURL
        (link_label) @linkLabel
        (link_title) @linkLabel
        (latex_block) @math
        (html_tag) @html
        [(backslash_escape) (entity_reference) (numeric_character_reference)] @escape
        """
        return try! Query(language: inline, data: Data(source.utf8))
    }()
}
