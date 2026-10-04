// Active content out of rendered HTML, for everything that leaves the app: Copy HTML, File > Export > HTML, the PDF and the
// `macdown2 render` output. The live preview keeps the document's raw HTML (Preferences > Markdown > raw HTML) and defends itself
// with a CSP, `stripActiveContent` and the navigation policy; a file or a clipboard has none of those, so the markup itself must
// be safe. Same list of elements the preview strips, plus what a CSP would have refused there: event-handler attributes and
// script-bearing URLs.
//
// It is not a regex over the HTML. The text is cut into tags the way an HTML tokenizer does it, and every tag that is kept
// is written out again from its parsed name and attributes (always double-quoted, `<` `>` `"` in values escaped), so what a
// browser reads is what was checked here. Anything that is not a complete tag stays text.
//
// Kept on purpose: `<style>` (the preview shows it; its `@import` and non-web `url()` are removed), `<form>` and its fields (the
// `action` is removed), `<svg>`, `<details>`, `data-*`, `id`, `class`, `style`.

const DROP = new Set([
  'script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'meta', 'base', // what the preview strips
  'link', 'param', 'noembed', 'noframes', 'xmp', 'plaintext', 'noscript', 'portal', // stylesheets/prefetch, parsed as text by some browsers
  'set', 'animate', 'animatemotion', 'animatetransform', // SVG animation can set `href` to a javascript: URL
]);
// Their content is not markup for a browser (or is a document of its own), so it goes with them.
const DROP_CONTENT = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'applet', 'noembed', 'noframes', 'xmp', 'plaintext', 'noscript']);

const URL_ATTRS = new Set(['href', 'src', 'xlink:href', 'poster', 'background', 'cite', 'longdesc', 'manifest', 'data', 'codebase', 'profile', 'usemap']);
const DROP_ATTRS = new Set(['srcdoc', 'action', 'formaction', 'ping', 'http-equiv', 'nonce']);
const SCHEMES = new Set(['http', 'https', 'mailto', 'tel', 'ftp']);
const DATA_IMAGE = /^data:image\/(?:png|jpe?g|gif|webp|avif|bmp|x-icon|svg\+xml)[;,]/;
const NAMED: Record<string, string> = { colon: ':', tab: '\t', newline: '\n', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', sol: '/', lpar: '(', rpar: ')' };

const isSpace = (c: string): boolean => c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f';
const isAlpha = (c: string): boolean => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

function decodeEntities(s: string): string {
  return s.replace(/&(?:#[xX]([0-9a-fA-F]{1,8})|#([0-9]{1,8})|([a-zA-Z][a-zA-Z0-9]{1,8}));?/g, (whole, hex: string | undefined, dec: string | undefined, name: string | undefined) => {
    if (name) return NAMED[name.toLowerCase()] ?? whole;
    const n = hex !== undefined ? parseInt(hex, 16) : parseInt(dec!, 10);
    return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '�';
  });
}

/** Whether a URL attribute value may stay. Entities are decoded and every control character and space removed first, as a browser
 *  does before it looks at the scheme (`java&#9;script:`, `\u0001javascript:`). No scheme (relative, `#frag`, `//host`) is fine. */
export function safeUrl(value: string, attr: string): boolean {
  const url = decodeEntities(value).replace(/[\u0000-\u0020\u007f-\u009f\u200b-\u200f\u2028\u2029\ufeff]/g, '').toLowerCase();
  const scheme = /^([a-z][a-z0-9+.-]*):/.exec(url)?.[1];
  if (scheme === undefined) return true;
  if (SCHEMES.has(scheme)) return true;
  return scheme === 'data' && (attr === 'src' || attr === 'poster') && DATA_IMAGE.test(url);
}

function cleanStyle(css: string): string {
  return css
    .replace(/@import\b[^;{]*;?/gi, '')
    .replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|((?:[^()\\]|\\.|\([^)]*\))*))\s*\)/gi, (whole, a: string | undefined, b: string | undefined, c: string | undefined) => {
      const target = (a ?? b ?? c ?? '').trim();
      return target === '' || safeUrl(target, 'src') ? whole : 'url()';
    });
}

const escapeAttr = (v: string): string => v.replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

interface Tag { name: string; written: string; attrs: [string, string, string | null][]; end: number; selfClosing: boolean } // attrs: lower-case name, name as written, value (null: none, `<details open>`)

/** The start tag at `i` (`html[i] === '<'`, a letter follows), or null when the tag is not complete. */
function readStartTag(html: string, i: number): Tag | null {
  const n = html.length;
  let p = i + 1;
  const nameStart = p;
  while (p < n && !isSpace(html[p]) && html[p] !== '/' && html[p] !== '>') p++;
  const written = html.slice(nameStart, p);
  const name = written.toLowerCase();
  const attrs: [string, string, string | null][] = [];
  let selfClosing = false;
  for (;;) {
    while (p < n && (isSpace(html[p]) || html[p] === '/')) {
      selfClosing = html[p] === '/';
      p++;
    }
    if (p >= n) return null;
    if (html[p] === '>') return { name, written, attrs, end: p + 1, selfClosing };
    selfClosing = false;
    const attrStart = p;
    p++; // a first `=` belongs to the name, as in the spec
    while (p < n && !isSpace(html[p]) && html[p] !== '/' && html[p] !== '>' && html[p] !== '=') p++;
    const attrWritten = html.slice(attrStart, p);
    const attrName = attrWritten.toLowerCase();
    while (p < n && isSpace(html[p])) p++;
    let value: string | null = null;
    if (html[p] === '=') {
      p++;
      while (p < n && isSpace(html[p])) p++;
      if (html[p] === '"' || html[p] === "'") {
        const close = html.indexOf(html[p], p + 1);
        if (close < 0) return null;
        value = html.slice(p + 1, close);
        p = close + 1;
      } else {
        const valueStart = p;
        while (p < n && !isSpace(html[p]) && html[p] !== '>') p++;
        value = html.slice(valueStart, p);
      }
    }
    if (!attrs.some(([existing]) => existing === attrName)) attrs.push([attrName, attrWritten, value]); // the first of a repeated attribute wins, as in a browser
  }
}

function writeTag(tag: Tag): string {
  const kept: string[] = [];
  for (const [name, written, value] of tag.attrs) {
    if (!/^[a-z_:][-a-z0-9_:.]*$/.test(name) || name.startsWith('on') || DROP_ATTRS.has(name)) continue;
    if (URL_ATTRS.has(name) && !safeUrl(value ?? '', name)) continue;
    if (value === null) kept.push(written);
    else kept.push(`${written}="${escapeAttr(name === 'style' ? cleanStyle(value) : value)}"`);
  }
  return `<${tag.written}${kept.length ? ' ' + kept.join(' ') : ''}${tag.selfClosing ? '/' : ''}>`;
}

export function sanitizeHtml(html: string): string {
  if (!html.includes('<')) return html;
  let out = '';
  let i = 0;
  const n = html.length;
  while (i < n) {
    const lt = html.indexOf('<', i);
    if (lt < 0) {
      out += html.slice(i);
      break;
    }
    out += html.slice(i, lt);
    const next = html[lt + 1] ?? '';
    if (html.startsWith('<!--', lt)) { // a comment (also `<!-->` and `<!--->`); comments are not content anywhere we write
      const end = html.indexOf('-->', lt + 4);
      i = html.startsWith('<!-->', lt) ? lt + 5 : html.startsWith('<!--->', lt) ? lt + 6 : end < 0 ? n : end + 3;
    } else if (next === '!' || next === '?') { // doctype, CDATA, processing instruction: a bogus comment up to `>`
      const close = html.indexOf('>', lt);
      i = close < 0 ? n : close + 1;
    } else if (next === '/' && isAlpha(html[lt + 2] ?? '')) {
      const close = html.indexOf('>', lt);
      if (close < 0) {
        out += '&lt;' + html.slice(lt + 1);
        break;
      }
      const written = html.slice(lt + 2, close).split(/[\s/]/, 1)[0];
      if (!DROP.has(written.toLowerCase()) && /^[a-zA-Z][a-zA-Z0-9:-]*$/.test(written)) out += `</${written}>`;
      i = close + 1;
    } else if (isAlpha(next)) {
      const tag = readStartTag(html, lt);
      if (!tag || !/^[a-z][a-z0-9:-]*$/.test(tag.name)) { // never closed (a browser would swallow the rest of the text into it) or not a name: text
        out += '&lt;';
        i = lt + 1;
        continue;
      }
      i = tag.end;
      if (DROP.has(tag.name)) {
        if (DROP_CONTENT.has(tag.name) && !tag.selfClosing) {
          const close = new RegExp(`</${tag.name}(?=[\\s/>])`, 'ig');
          close.lastIndex = i;
          const found = close.exec(html);
          if (found) {
            const end = html.indexOf('>', found.index);
            i = end < 0 ? n : end + 1;
          } else {
            i = n;
          }
        }
        continue;
      }
      out += writeTag(tag);
      if (tag.name === 'style' && !tag.selfClosing) { // the CSS inside is text for a browser: clean it as CSS, not as markup
        const found = /<\/style(?=[\s/>])/i.exec(html.slice(i));
        const end = found ? i + found.index : n;
        out += cleanStyle(html.slice(i, end));
        i = end;
      }
    } else {
      out += '<'; // `a < b`: text
      i = lt + 1;
    }
  }
  return out;
}
