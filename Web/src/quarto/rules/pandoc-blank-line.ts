// Pandoc's blank-line rules (PLAN 4.6.1, "已知偏差"): in Pandoc Markdown, which Quarto reads, a line that would start a heading, a
// block quote or a list does NOT interrupt a paragraph; it needs a blank line before it. CommonMark (markdown-it) lets all three
// interrupt, so `text\n# not a heading` renders differently in the preview than in the real Quarto output.
//
// Checked against Pandoc's reader (Text.Pandoc.Readers.Markdown, `para` and `endline`) and its manual:
//   - `blank_before_header` (on in `markdown`): "Pandoc does require [a blank line before a heading] (except, of course, at the
//     beginning of the document)". `text\n#22, for example` is one paragraph.
//   - `blank_before_blockquote` (on): "the following does not produce a nested block quote in pandoc: `> a` / `>> b`";
//     a `>` line right after paragraph text is text.
//   - `lists_without_preceding_blankline` (OFF in `markdown`; Quarto turns it on only for its markdown *writers*, not for the
//     .qmd reader): "Allow a list to occur right after a paragraph, with no intervening blank space", so by default a list
//     needs the blank line. Inside a list item a list marker still starts the next (or a nested) item: `endline` has
//     `notFollowedBy (inList >> listStart)`.
// What does still interrupt a paragraph in Pandoc, and is left to markdown-it: a backtick fence, a setext underline (`---`,
// `===`; it makes the line above a heading), the end of a fenced div / HTML `<div>`. Not touched because the Pandoc docs do not
// say (thematic breaks, HTML blocks, tables): markdown-it's behaviour stays.
//
// lazy: the blank-line rule is applied to paragraphs and to the lazy continuation lines of a block quote only; a heading or list
// right after the *last line of a list item* behaves as in Pandoc (it is text), but Pandoc's "fancy" list markers (`a.`, `(i)`,
// `#.`) are not list starts here, as everywhere else in the preview. Upgrade = a `fancy_lists` rule.
import type { MarkdownIt } from 'markdown-it';

/** Block rules that markdown-it lets end a paragraph (alt chain 'paragraph') and that Pandoc does not. */
const BLOCKS = ['heading', 'blockquote', 'alert', 'list'];

export function pandocBlankLine(md: MarkdownIt): void {
  const ruler = md.block.ruler;
  for (const rule of [...ruler.__rules__]) {
    if (!BLOCKS.includes(rule.name) || !rule.alt.includes('paragraph')) continue;
    // A heading or a list that follows a quote line is part of the quote's lazy text too (`blockQuote` collects such lines raw).
    const alt = rule.alt.filter((a) => a !== 'paragraph' && (a !== 'blockquote' || rule.name === 'blockquote' || rule.name === 'alert'));
    ruler.at(rule.name, rule.fn, { alt });
    if (rule.name !== 'list') continue;
    // The one exception: in a list item the next marker line starts the next item (markdown-it ends the item's paragraph at it;
    // `listIndent` is >= 0 only while an item's content is parsed, `parentType` is already 'paragraph' when a terminator runs).
    const list = rule.fn;
    ruler.before('paragraph', 'pandoc_list_in_list', (state, start, end, silent) => silent && state.listIndent >= 0 && list(state, start, end, true), {
      alt: ['paragraph'],
    });
  }
}
