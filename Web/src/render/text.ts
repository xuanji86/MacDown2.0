// Pure text helpers shared by the renderer: word counting, heading slugs, block hashes.

export interface TextStats {
  words: number;
  characters: number;
  charactersNoSpaces: number;
}

// Han, kana and other scripts written without spaces count one word per character.
const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}々ー]/gu;
const WORD = /[\p{L}\p{N}\p{M}]+(?:['’][\p{L}\p{N}\p{M}]+)*/gu;
const graphemes = new Intl.Segmenter('und', { granularity: 'grapheme' });

export function textStats(text: string): TextStats {
  const cjk = text.match(CJK)?.length ?? 0;
  const latin = text.replace(CJK, ' ').match(WORD)?.length ?? 0;
  let characters = 0;
  let charactersNoSpaces = 0;
  for (const { segment } of graphemes.segment(text)) {
    if (segment === '\n') continue;
    characters++;
    if (!/^\s+$/u.test(segment)) charactersNoSpaces++;
  }
  return { words: cjk + latin, characters, charactersNoSpaces };
}

// GitHub-style heading slug: lowercase, drop punctuation, spaces to hyphens, dedupe with -1, -2…
export function slugify(text: string, seen: Map<string, number>): string {
  const base = text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '')
    .replace(/\s/g, '-');
  const count = seen.get(base) ?? 0;
  seen.set(base, count + 1);
  return count === 0 ? base : `${base}-${count}`;
}

// cyrb53: fast 53-bit string hash, safe to pass through JSON as a Number.
export function hash53(str: string): number {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}
