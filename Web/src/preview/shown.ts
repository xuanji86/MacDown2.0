// What the page shows right now, for the parts that work on it after a render (source map, selection, editing): the Markdown and
// options of the render that was last applied to the DOM, its version, and its blocks. main.ts keeps it current.
import type { BlockHandle } from './scroll.ts';

export interface RenderOptionsLike {
  flavor: string;
  extensions: string[];
  [key: string]: unknown;
}

export const shown = {
  source: '',
  options: null as RenderOptionsLike | null,
  optionsJSON: '',
  version: 0,
  blocks: [] as BlockHandle[],
  /** Bumped whenever the DOM of #doc changes under a render (patch or rebuild). */
  generation: 0,
};

let starts: { source: string; at: Int32Array } | null = null;

/** Offsets of the starts of the source's lines (cached per source string). */
export function lineStarts(source: string): Int32Array {
  if (starts?.source === source) return starts.at;
  let n = 1;
  for (let p = source.indexOf('\n'); p >= 0; p = source.indexOf('\n', p + 1)) n++;
  const at = new Int32Array(n);
  let i = 1;
  for (let p = source.indexOf('\n'); p >= 0; p = source.indexOf('\n', p + 1)) at[i++] = p + 1;
  starts = { source, at };
  return at;
}

/** 0-based line of `offset` in `source`. */
export function lineOf(source: string, offset: number): number {
  const at = lineStarts(source);
  let lo = 0;
  let hi = at.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (at[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/** [start, end) of the source lines line0 ..< line1, without the last line's newline. */
export function linesRange(source: string, line0: number, line1: number): [number, number] {
  const at = lineStarts(source);
  const start = line0 < at.length ? at[line0] : source.length;
  const end = line1 < at.length ? at[line1] - 1 : source.length;
  return [start, Math.max(start, end)];
}
