// The text of a block that the inline source map speaks about: its text nodes in document order, minus what the renderer makes
// up rather than copies from the source (KaTeX output, footnote reference numbers, the [TOC] list, diagrams) and what never shows
// as text (scripts, styles, templates). Written against the few DOM members it needs, so the node tests can run it on parse5 trees.

export interface DomainNode {
  nodeType: number;
  childNodes: ArrayLike<DomainNode>;
  /** text nodes */
  data?: string;
  /** elements */
  localName?: string;
  getAttribute?(name: string): string | null;
}

const SKIP_TAGS = new Set(['script', 'style', 'template', 'textarea', 'noscript', 'svg', 'math', 'iframe', 'object']);
const SKIP_CLASSES = ['katex', 'katex-display', 'katex-error', 'katex-block'];

function skipped(el: DomainNode): boolean {
  const tag = el.localName ?? '';
  if (SKIP_TAGS.has(tag)) return true;
  const cls = el.getAttribute?.('class');
  if (cls) {
    const names = cls.split(/\s+/);
    if (SKIP_CLASSES.some((c) => names.includes(c))) return true;
    if (tag === 'sup' && names.includes('footnote-ref')) return true;
    if (tag === 'nav' && names.includes('toc')) return true;
    if (names.includes('mermaid')) return true;
  }
  if (el.getAttribute?.('data-include') !== null && el.getAttribute?.('data-include') !== undefined) return true;
  return false;
}

/** The text nodes of `roots` (and their subtrees) that belong to the mapped text, in document order. */
export function domainTexts<T extends DomainNode>(roots: ArrayLike<T>): T[] {
  const out: T[] = [];
  const walk = (n: DomainNode): void => {
    if (n.nodeType === 3) {
      out.push(n as T);
      return;
    }
    if (n.nodeType !== 1 || skipped(n)) return;
    const kids = n.childNodes;
    for (let i = 0; i < kids.length; i++) walk(kids[i]);
  };
  for (let i = 0; i < roots.length; i++) walk(roots[i]);
  return out;
}

/** Puts the sentinels of `probe` back and checks the result is exactly `live` (the text the page shows): then each sentinel's
 *  position is its character's place in `live`. Returns, per unit of `live`, the block offset of the character there (-1: none),
 *  or null when the probe's text is not the page's text (the block parses differently on its own: unmappable). */
export function readProbe(live: string, probeText: string, probe: { sentinels: string; originals: string; offsets: number[] }): Int32Array | null {
  if (probeText.length !== live.length) return null;
  const index = new Map<number, number>();
  for (let i = 0; i < probe.sentinels.length; i++) index.set(probe.sentinels.charCodeAt(i), i);
  const out = new Int32Array(live.length).fill(-1);
  const seen = new Int32Array(probe.sentinels.length).fill(-1);
  for (let k = 0; k < live.length; k++) {
    const c = probeText.charCodeAt(k);
    const i = index.get(c);
    if (i === undefined) {
      if (c !== live.charCodeAt(k)) return null;
      continue;
    }
    if (probe.originals.charCodeAt(i) !== live.charCodeAt(k)) return null;
    if (seen[i] >= 0) {
      out[seen[i]] = -1; // shown twice: neither copy is the one
      seen[i] = -2;
      continue;
    }
    if (seen[i] === -2) continue;
    seen[i] = k;
    out[k] = probe.offsets[i];
  }
  return out;
}
