// Character alignment for the inline source map (inline-map.ts): which characters of `b` are characters of `a` that a rewrite
// kept, when the rewrite only removes and inserts local runs (emphasis markers taken out, `--` -> `–`, `:smile:` -> `😄`, a task box
// cut off, `"` -> `“`). Myers' O(ND) diff, then every kept character that a removed or inserted run could have taken the place of
// is given up: in `***a**` -> `*a` the surviving `*` is one of three and a diff picks one at random.
//
// lazy: gives up (nothing kept) beyond MAX_D edits; upgrade = a linear-space diff if long rewritten paragraphs show up.
const MAX_D = 512;

/** For each UTF-16 unit of `b`, the index of the unit of `a` it is, or -1 (inserted, or ambiguous). */
export function alignKept(a: string, b: string): Int32Array {
  const out = new Int32Array(b.length).fill(-1);
  if (a === b) {
    for (let i = 0; i < b.length; i++) out[i] = i;
    return out;
  }
  let pre = 0;
  const min = Math.min(a.length, b.length);
  while (pre < min && a.charCodeAt(pre) === b.charCodeAt(pre)) pre++;
  let suf = 0;
  while (suf < min - pre && a.charCodeAt(a.length - 1 - suf) === b.charCodeAt(b.length - 1 - suf)) suf++;
  const pairs = myers(a.slice(pre, a.length - suf), b.slice(pre, b.length - suf));
  if (!pairs) return out;
  // kept[j] = index in a, for the whole strings
  const kept = new Int32Array(b.length).fill(-1);
  for (let i = 0; i < pre; i++) kept[i] = i;
  for (let k = 0; k < pairs.length; k += 2) kept[pre + pairs[k + 1]] = pre + pairs[k];
  for (let i = 0; i < suf; i++) kept[b.length - 1 - i] = a.length - 1 - i;
  // Hunks: maximal runs where a and b do not advance together. The kept characters next to a hunk that equal a character the hunk
  // removed or inserted could have been the other one: give them up, outward, as long as they keep matching.
  let ia = 0;
  let ib = 0;
  const ambiguous = new Uint8Array(b.length);
  while (ib <= b.length) {
    // advance through a kept run
    while (ib < b.length && kept[ib] === ia) {
      ia++;
      ib++;
    }
    if (ib === b.length && ia === a.length) break;
    // a hunk: a[ia, na) removed, b[ib, nb) inserted, up to the next kept character
    let nb = ib;
    while (nb < b.length && kept[nb] < 0) nb++;
    const na = nb < b.length ? kept[nb] : a.length;
    const chars = new Set<number>();
    for (let i = ia; i < na; i++) chars.add(a.charCodeAt(i));
    for (let i = ib; i < nb; i++) chars.add(b.charCodeAt(i));
    for (let j = ib - 1; j >= 0 && kept[j] >= 0 && chars.has(b.charCodeAt(j)); j--) ambiguous[j] = 1;
    for (let j = nb; j < b.length && kept[j] >= 0 && chars.has(b.charCodeAt(j)); j++) ambiguous[j] = 1;
    if (nb >= b.length) break;
    ia = na;
    ib = nb;
  }
  for (let j = 0; j < b.length; j++) out[j] = ambiguous[j] ? -1 : kept[j];
  return out;
}

// Myers' greedy diff (Myers 1986, "An O(ND) Difference Algorithm"): the matched pairs [ia, ib, ...] of a shortest edit script, or
// null past MAX_D.
function myers(a: string, b: string): number[] | null {
  const n = a.length;
  const m = b.length;
  if (n === 0 || m === 0) return [];
  const max = Math.min(n + m, MAX_D);
  const off = max + 1;
  let v = new Int32Array(2 * max + 3);
  const trace: Int32Array[] = [];
  let found = -1;
  for (let d = 0; d <= max; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a.charCodeAt(x) === b.charCodeAt(y)) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break;
      }
    }
    if (found >= 0) break;
  }
  if (found < 0) return null;
  // Walk back through the trace: diagonals are matches.
  const pairs: number[] = [];
  let x = n;
  let y = m;
  for (let d = found; d > 0; d--) {
    const pv = trace[d];
    const k = x - y;
    const prevK = k === -d || (k !== d && pv[off + k - 1] < pv[off + k + 1]) ? k + 1 : k - 1;
    const prevX = pv[off + prevK];
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
      pairs.push(y, x);
    }
    x = prevX;
    y = prevY;
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    pairs.push(y, x);
  }
  // pairs were pushed as [ib, ia] backwards; return [ia, ib] forwards
  const outPairs: number[] = [];
  for (let k = pairs.length - 2; k >= 0; k -= 2) outPairs.push(pairs[k + 1], pairs[k]);
  return outPairs;
}
