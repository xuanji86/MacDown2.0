// What the page shows right now, for the parts that work on it after a render (source map, selection, editing): the Markdown and
// options of the render that was last applied to the DOM, its version, its blocks and its task checkboxes. main.ts keeps it current.
import type { BlockHandle } from './scroll.ts';
import { lastLE } from './scroll-map.ts';

export interface RenderOptionsLike {
  flavor: string;
  extensions: string[];
  [key: string]: unknown;
}

/** A task-list checkbox of the render (render/core.ts `tasksOf`): its item's line, and the line and column of its `[ ]` mark. */
export interface TaskItem { line: number; mark: number; column: number }

export const shown = {
  source: '',
  options: null as RenderOptionsLike | null,
  optionsJSON: '',
  version: 0,
  blocks: [] as BlockHandle[],
  tasks: [] as TaskItem[],
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
  return Math.max(0, lastLE(at.length, (i) => at[i], offset));
}

/** The block whose source lines hold `line` (the footnote section and comment-only blocks have lines of none). */
export function blockAt(line: number): BlockHandle | undefined {
  const blocks = shown.blocks;
  const h = blocks[lastLE(blocks.length, (i) => blocks[i].line0, line)];
  return h && line < h.line1 ? h : undefined;
}

/** [start, end) of the source lines line0 ..< line1, without the last line's newline. */
export function linesRange(source: string, line0: number, line1: number): [number, number] {
  const at = lineStarts(source);
  const start = line0 < at.length ? at[line0] : source.length;
  const end = line1 < at.length ? at[line1] - 1 : source.length;
  return [start, Math.max(start, end)];
}
