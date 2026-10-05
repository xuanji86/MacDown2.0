// The page's view of a piece of HTML, outside a browser: parse5 (the HTML specification's parser) with a <div> as the context
// element, as the page's `innerHTML` on a <div> has it, wrapped in the few DOM members src/preview/text-domain.ts reads.
import { defaultTreeAdapter, html as ns, parseFragment } from 'parse5';
import { domainTexts } from '../../src/preview/text-domain.ts';
import { alignSegments, splitBlocks } from '../../src/preview/split-html.ts';

const context = defaultTreeAdapter.createElement('div', ns.NS.HTML, []);

function wrap(n) {
  if (n.nodeName === '#text') return { nodeType: 3, data: n.value, childNodes: [] };
  if (n.nodeName === '#comment') return { nodeType: 8, data: n.data, childNodes: [] };
  const kids = n.nodeName === 'template' ? n.content.childNodes : n.childNodes ?? [];
  return {
    nodeType: 1,
    localName: n.tagName,
    getAttribute: (name) => n.attrs?.find((a) => a.name === name)?.value ?? null,
    childNodes: kids.map(wrap),
  };
}

export function nodesOf(html) {
  return parseFragment(context, html).childNodes.map(wrap);
}

/** The text a block's HTML shows, as the source map counts it. */
export function textOf(html) {
  return domainTexts(nodesOf(html)).map((t) => t.data).join('');
}

/** The same text with the index where each text node starts (a caret at a node boundary belongs to one of the two nodes). */
export function textNodesOf(html) {
  const starts = [];
  let text = '';
  for (const t of domainTexts(nodesOf(html))) {
    starts.push(text.length);
    text += t.data;
  }
  return { text, starts };
}

/** The rendered document's top-level blocks' HTML, as the page cuts it (null when it cannot be cut). */
export function blockHTML(result) {
  const segs = alignSegments(result.html, splitBlocks(result.html), result.blocks.length);
  if (!segs) return null;
  return segs.filter((s) => !s.tail).map((s) => result.html.slice(s.start, s.end));
}

export function lineStartsOf(text) {
  const out = [0];
  for (let p = text.indexOf('\n'); p >= 0; p = text.indexOf('\n', p + 1)) out.push(p + 1);
  return out;
}

/** [start, end) of lines line0 ..< line1, without the last newline (shown.ts linesRange). */
export function linesRange(text, line0, line1) {
  const at = lineStartsOf(text);
  const start = line0 < at.length ? at[line0] : text.length;
  const end = line1 < at.length ? at[line1] - 1 : text.length;
  return [start, Math.max(start, end)];
}
