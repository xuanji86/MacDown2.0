// Source line <-> page y by piecewise-linear interpolation between anchors (PLAN 4.4.4). Pure.
// An anchor is a block with its source line range and its laid-out box; anchors come in ascending line and y order.
// `at(i)` is lazy so a caller with thousands of blocks measures only the ones the binary search touches.

export interface Anchor {
  line0: number; // first source line (0-based)
  line1: number; // line after the last one (exclusive)
  top: number;
  bottom: number;
}

const lerp = (x: number, x0: number, x1: number, y0: number, y1: number): number => (x1 > x0 ? y0 + ((x - x0) / (x1 - x0)) * (y1 - y0) : y0);

// Largest i in [0, n) with key(i) <= x, or -1.
export function lastLE(n: number, key: (i: number) => number, x: number): number {
  let lo = 0;
  let hi = n - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (key(mid) <= x) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found;
}

export function lineToY(line: number, n: number, at: (i: number) => Anchor): number {
  const i = lastLE(n, (k) => at(k).line0, line);
  if (i < 0) return 0;
  const a = at(i);
  if (line < a.line1) return lerp(line, a.line0, a.line1, a.top, a.bottom);
  if (i === n - 1) return a.bottom;
  const b = at(i + 1); // blank lines between two blocks
  return lerp(line, a.line1, b.line0, a.bottom, b.top);
}

export function yToLine(y: number, n: number, at: (i: number) => Anchor): number {
  const i = lastLE(n, (k) => at(k).top, y);
  if (i < 0) return 0;
  const a = at(i);
  if (y < a.bottom) return lerp(y, a.top, a.bottom, a.line0, a.line1);
  if (i === n - 1) return a.line1;
  const b = at(i + 1);
  return lerp(y, a.bottom, b.top, a.line1, b.line0);
}
