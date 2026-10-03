// CJK-friendly emphasis (the idea behind comrak's `cjk_friendly_emphasis` and the CommonMark
// "CJK friendly" proposal by tats-u).
//
// CommonMark decides whether a `*`/`_`/`~` delimiter run can open or close from the characters on both
// sides. When one side is punctuation and the other is a letter, the run only counts if the letter side
// is whitespace-like, which breaks `**「重点」**的`: the closing run follows `」` and precedes `的`.
// CJK text has no spaces, so here a CJK character on the letter side counts like whitespace/punctuation:
//   left-flanking  (2b): followed by punctuation  and preceded by whitespace | punctuation | CJK
//   right-flanking (2b): preceded by punctuation  and followed by whitespace | punctuation | CJK
// Everything else, including the `_` intraword rule, is stock CommonMark/markdown-it.
//
// Installed per markdown-it instance by swapping `md.inline.State`, so other instances stay untouched.
// Not covered (lazy: upgrade = a separate inline rule or the full proposal): CJK line-break joining
// (a soft break between CJK lines still renders as a space) and `_` emphasis directly against CJK letters.
import type { MarkdownIt, StateInline } from 'markdown-it';

// Script_Extensions (not Script) so U+30FC ー and 々 count; E0100-E01EF are ideographic variation selectors.
const CJK = /[\p{scx=Han}\p{scx=Hiragana}\p{scx=Katakana}\p{scx=Hangul}\p{scx=Bopomofo}\u{E0100}-\u{E01EF}]/u;
const isCJK = (cp: number): boolean => cp > 0xff &&CJK.test(String.fromCodePoint(cp));

function codePointBefore(src: string, pos: number): number {
  if (pos === 0) return 0x20;
  const lo = src.charCodeAt(pos - 1);
  if ((lo & 0xfc00) === 0xdc00 && pos > 1) {
    const hi = src.charCodeAt(pos - 2);
    if ((hi & 0xfc00) === 0xd800) return 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00);
  }
  return (lo & 0xf800) === 0xd800 ? 0xfffd : lo;
}

function codePointAt(src: string, pos: number, max: number): number {
  if (pos >= max) return 0x20;
  const cp = src.codePointAt(pos)!;
  return (cp & 0xfffff800) === 0xd800 ? 0xfffd : cp; // lone surrogate
}

export function cjkEmphasis(md: MarkdownIt): void {
  const { isWhiteSpace, isPunctChar, isMdAsciiPunct } = md.utils;
  const isPunct = (cp: number): boolean => isMdAsciiPunct(cp) || isPunctChar(String.fromCodePoint(cp));
  const Base = md.inline.State as typeof StateInline;

  class CjkState extends Base {
    scanDelims(start: number, canSplitWord: boolean) {
      const stock = super.scanDelims(start, canSplitWord);
      const last = codePointBefore(this.src, start);
      const next = codePointAt(this.src, start + stock.length, this.posMax);
      const lastCJK = isCJK(last);
      const nextCJK = isCJK(next);
      if (!lastCJK && !nextCJK) return stock;

      const lastPunct = isPunct(last);
      const nextPunct = isPunct(next);
      const lastSpace = isWhiteSpace(last);
      const nextSpace = isWhiteSpace(next);
      const left = !nextSpace && (!nextPunct || lastSpace || lastPunct || lastCJK);
      const right = !lastSpace && (!lastPunct || nextSpace || nextPunct || nextCJK);
      return {
        can_open: left && (canSplitWord || !right || lastPunct),
        can_close: right && (canSplitWord || !left || nextPunct),
        length: stock.length,
      };
    }
  }
  md.inline.State = CjkState;
}
