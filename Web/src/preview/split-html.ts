// Cuts the renderer's HTML string into one segment per top-level block, with a content hash per segment.
//
// Why here: render returns a single `html` string plus per-block metadata, not per-block HTML (PLAN 4.1.2 wants
// the latter). Until render grows it, the preview recovers block boundaries by tracking tag depth: a segment
// ends when depth returns to 0, the next depth-0 element starts the next one. Text between blocks ("\n")
// stays with the segment before it, so the segments concatenate back to exactly the input.
//
// The hash ignores ` data-line="N"` / ` data-line-end="N"` attributes: inserting a line above a block moves
// every following block's line numbers but must not make it look changed.
//
// lazy: raw HTML that is not balanced per block (`<div>` and `</div>` in separate html_blocks, unclosed
// `<p>`/`<li>`) yields the wrong segment count; the caller compares against blocks.length and falls back to a
// full render. Upgrade path: render emits per-block HTML, then delete this file.

export interface Segment {
  start: number;
  end: number;
  hash: number; // 53-bit, ignores data-line attributes
  tail?: boolean; // footnote section: rendered after the last block, has no entry in `blocks`
}

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
const RAW_TEXT = new Set(['script', 'style', 'textarea', 'title']);

const isSpace = (c: number): boolean => c === 32 || c === 10 || c === 9 || c === 13 || c === 12;
const isAlpha = (c: number): boolean => (c >= 97 && c <= 122) || (c >= 65 && c <= 90);

// Returns the index just past the tag's '>' (`p` is just after the tag name), -1 if unterminated.
// Pushes [from, to) of every data-line / data-line-end attribute (with its leading space) onto `skips`.
function tagEnd(html: string, p: number, skips: number[]): number {
  const n = html.length;
  for (;;) {
    while (p < n && isSpace(html.charCodeAt(p))) p++;
    if (p >= n) return -1;
    const c = html.charCodeAt(p);
    if (c === 62) return p + 1;
    if (c === 47) {
      p++;
      continue;
    }
    const nameStart = p;
    while (p < n) {
      const d = html.charCodeAt(p);
      if (isSpace(d) || d === 61 || d === 62 || d === 47) break;
      p++;
    }
    const isLine = html.charCodeAt(nameStart) === 100 && (html.startsWith('data-line=', nameStart) || html.startsWith('data-line-end=', nameStart));
    while (p < n && isSpace(html.charCodeAt(p))) p++;
    if (html.charCodeAt(p) === 61) {
      p++;
      while (p < n && isSpace(html.charCodeAt(p))) p++;
      const q = html.charCodeAt(p);
      if (q === 34 || q === 39) {
        const close = html.indexOf(q === 34 ? '"' : "'", p + 1);
        if (close < 0) return -1;
        p = close + 1;
      } else {
        while (p < n && !isSpace(html.charCodeAt(p)) && html.charCodeAt(p) !== 62) p++;
      }
    }
    if (isLine) skips.push(nameStart - (isSpace(html.charCodeAt(nameStart - 1)) ? 1 : 0), p);
  }
}

// cyrb53 over html[a, b) minus the skip ranges skips[s0 .. s1).
export function hashRange(html: string, a: number, b: number, skips: number[], s0: number, s1: number): number {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  let k = s0;
  let nextSkip = k < s1 ? skips[k] : Infinity;
  for (let i = a; i < b; ) {
    if (i === nextSkip) {
      i = skips[k + 1];
      k += 2;
      nextSkip = k < s1 ? skips[k] : Infinity;
      continue;
    }
    const c = html.charCodeAt(i++);
    h1 = Math.imul(h1 ^ c, 2654435761);
    h2 = Math.imul(h2 ^ c, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}

// null when the markup is unbalanced or unterminated (caller falls back to a full render).
export function splitBlocks(html: string): Segment[] | null {
  const segments: Segment[] = [];
  const skips: number[] = [];
  let skipFrom = 0; // skips index where the current segment's ranges begin
  let start = 0;
  let depth = 0;
  let closed = false; // current segment already holds a complete depth-0 element
  let i = 0;

  const startElement = (at: number): void => {
    if (depth === 0 && closed) {
      segments.push({ start, end: at, hash: hashRange(html, start, at, skips, skipFrom, skips.length) });
      start = at;
      skipFrom = skips.length;
      closed = false;
    }
  };

  for (;;) {
    const lt = html.indexOf('<', i);
    if (lt < 0 || lt + 1 >= html.length) break;
    const c = html.charCodeAt(lt + 1);
    if (c === 47) {
      // closing tag
      const gt = html.indexOf('>', lt + 2);
      if (gt < 0 || --depth < 0) return null;
      if (depth === 0) closed = true;
      i = gt + 1;
    } else if (c === 33 || c === 63) {
      // comment / doctype / processing instruction: complete on its own
      startElement(lt);
      const isComment = html.startsWith('<!--', lt);
      const stop = html.indexOf(isComment ? '-->' : '>', lt + 2);
      if (stop < 0) return null;
      i = stop + (isComment ? 3 : 1);
      if (depth === 0) closed = true;
    } else if (isAlpha(c)) {
      startElement(lt);
      let p = lt + 2;
      while (p < html.length && !isSpace(html.charCodeAt(p)) && html.charCodeAt(p) !== 62 && html.charCodeAt(p) !== 47) p++;
      const name = html.slice(lt + 1, p).toLowerCase();
      const end = tagEnd(html, p, skips);
      if (end < 0) return null;
      i = end;
      if (VOID.has(name) || html.charCodeAt(end - 2) === 47) {
        if (depth === 0) closed = true;
      } else {
        depth++;
        if (RAW_TEXT.has(name)) {
          const close = new RegExp(`</${name}[\\s>]`, 'gi');
          close.lastIndex = i;
          const found = close.exec(html);
          if (!found) return null;
          i = found.index; // the loop then sees the closing tag
        }
      }
    } else {
      i = lt + 1; // a bare "<" in text
    }
  }
  if (depth !== 0) return null;
  if (closed) segments.push({ start, end: html.length, hash: hashRange(html, start, html.length, skips, skipFrom, skips.length) });
  else if (html.length > start) return null; // trailing text with no element: not what the renderer emits
  return segments;
}

const FOOTNOTES = '<hr class="footnotes-sep">';

// Lines the renderer's `blocks` up with segments: one segment per block, plus the footnote section (the
// `<hr class="footnotes-sep"><section class="footnotes">` pair, which has no block) merged into a single
// trailing `tail` segment. null when the counts cannot be explained that way.
export function alignSegments(html: string, segs: Segment[] | null, blockCount: number): Segment[] | null {
  if (!segs || segs.length < blockCount) return null;
  if (segs.length === blockCount) return segs;
  if (!html.startsWith(FOOTNOTES, segs[blockCount].start)) return null;
  const extra = segs.slice(blockCount);
  const start = extra[0].start;
  const end = extra[extra.length - 1].end;
  // Hashed with its data-line values: footnote paragraphs carry absolute source lines and are not shifted like blocks.
  return [...segs.slice(0, blockCount), { start, end, hash: hashRange(html, start, end, [], 0, 0), tail: true }];
}
