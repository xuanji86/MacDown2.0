// Block-level patch plan (PLAN 4.4.3). Pure: compares the old and new top-level block keys and says which blocks
// can stay in the DOM; main.ts applies it.
//
//   common prefix + common suffix are cut away, the middle gets an LCS so unchanged blocks inside an edit
//   (an inserted paragraph between two kept ones, a moved block) survive too.

export interface PatchPlan {
  prefix: number; // leading blocks identical in old and new
  suffix: number; // trailing blocks identical in old and new
  matches: Array<[oldIndex: number, newIndex: number]>; // LCS pairs inside the middle, ascending in both
}

// lazy: LCS table is N*M Uint16 cells; a middle bigger than this on either side is replaced wholesale.
// Typing touches 1-2 blocks; a 2000-block paste is not worth 8 MB of table. Upgrade path: Myers diff.
export const MAX_MIDDLE = 2000;

export function planPatch(oldKeys: ArrayLike<number>, newKeys: ArrayLike<number>): PatchPlan {
  const n = oldKeys.length;
  const m = newKeys.length;
  const common = Math.min(n, m);
  let prefix = 0;
  while (prefix < common && oldKeys[prefix] === newKeys[prefix]) prefix++;
  let suffix = 0;
  while (suffix < common - prefix && oldKeys[n - 1 - suffix] === newKeys[m - 1 - suffix]) suffix++;

  const rows = n - prefix - suffix;
  const cols = m - prefix - suffix;
  if (rows === 0 || cols === 0 || rows > MAX_MIDDLE || cols > MAX_MIDDLE) return { prefix, suffix, matches: [] };

  // lcs[i][j] = LCS length of old[prefix+i ..] and new[prefix+j ..]
  const w = cols + 1;
  const lcs = new Uint16Array((rows + 1) * w);
  for (let i = rows - 1; i >= 0; i--) {
    for (let j = cols - 1; j >= 0; j--) {
      lcs[i * w + j] =
        oldKeys[prefix + i] === newKeys[prefix + j]
          ? lcs[(i + 1) * w + j + 1] + 1
          : Math.max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
    }
  }
  const matches: Array<[number, number]> = [];
  for (let i = 0, j = 0; i < rows && j < cols; ) {
    if (oldKeys[prefix + i] === newKeys[prefix + j]) {
      matches.push([prefix + i, prefix + j]);
      i++;
      j++;
    } else if (lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) i++;
    else j++;
  }
  return { prefix, suffix, matches };
}
