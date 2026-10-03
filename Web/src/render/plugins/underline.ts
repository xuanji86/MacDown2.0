// `_x_` -> <u>x</u>. Only `em` tokens whose markup is `_` are touched; `*x*` stays <em>, `__x__` stays <strong>.
import type { MarkdownIt } from 'markdown-it';

export function underline(md: MarkdownIt): void {
  md.core.ruler.after('inline', 'macdown2_underline', (state) => {
    for (const t of state.tokens) {
      if (t.type !== 'inline') continue;
      for (const c of t.children ?? []) {
        if ((c.type === 'em_open' || c.type === 'em_close') && c.markup === '_') c.tag = 'u';
      }
    }
  });
}
