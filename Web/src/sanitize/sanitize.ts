// Active content out of rendered HTML, for everything that leaves the app: Copy HTML, File > Export > HTML, the PDF and the
// `macdown2 render` output. The live preview keeps the document's raw HTML (Settings > Markdown > raw HTML) and defends itself
// with a CSP, `stripActiveContent` and the navigation policy; a file or a clipboard has none of those, so the markup itself must
// be safe.
//
// An allowlist over a real parse. The HTML is parsed with parse5, which implements the HTML specification's tokenizer and tree
// builder (entities, foreign content for <svg> and <math>, the breakout rules, foster parenting, raw-text and RCDATA elements), so
// what is checked here is the tree a browser builds, not a guess about it from the text. Only allowlisted elements and attributes
// are written back; attribute values arrive already entity-decoded, so URL schemes are checked on what the browser will see.
//
// mXSS (markup that parses differently after being serialized and parsed again) is closed by a fixed-point check: the output is
// parsed and cleaned once more and must come back byte for byte. If it does not settle within a few passes the whole thing is
// returned as escaped text. Cost: the document is parsed two or three times, on export and copy only.
//
// What is kept on purpose: ordinary text markup, tables, forms without an action, `<details>`, `<style>` (HTML namespace only; its
// `@import` and non-web `url()` are removed), inline `style`, `data-*`/`aria-*`, `id`, `class`, and the SVG and MathML that KaTeX writes.
import { defaultTreeAdapter, html as ns, parseFragment, serialize, type DefaultTreeAdapterMap } from 'parse5';

type El = DefaultTreeAdapterMap['element'];
type Child = DefaultTreeAdapterMap['childNode'];

const words = (s: string): Set<string> => new Set(s.split(/\s+/).filter(Boolean));

const HTML_TAGS = words(`a abbr acronym address article aside b bdi bdo big blockquote br button caption center cite code col colgroup data dd del details
  dfn div dl dt em fieldset figcaption figure font footer form h1 h2 h3 h4 h5 h6 header hgroup hr i img input ins kbd label legend li main mark menu meter
  nav ol output p pre progress q rp rt ruby s samp section small span strike strong style sub summary sup table tbody td tfoot th thead time tr tt u ul var wbr`);
// Dropped with everything inside them. Anything else that is not allowed is unwrapped: its children stay.
const DROP_WITH_CONTENT = words(`script iframe frame frameset object embed applet param meta base link noscript noembed noframes template xmp plaintext textarea title
  select option optgroup datalist audio video source track canvas dialog portal slot`);

const SVG_TAGS = words(`svg g path circle ellipse line polygon polyline rect text tspan defs linearGradient radialGradient stop clipPath mask pattern marker symbol title desc`);
const MATH_TAGS = words(`math semantics annotation mrow mi mn mo mtext mspace ms msup msub msubsup mfrac msqrt mroot mover munder munderover mtable mtr mtd mlabeledtr
  mstyle mpadded mphantom menclose merror mmultiscripts mprescripts none`);

const GLOBAL_ATTRS = words(`class id title lang dir role hidden style translate`);
const HTML_ATTRS: Record<string, Set<string>> = {
  a: words('href target rel name'),
  img: words('src alt width height'),
  td: words('colspan rowspan headers align valign width'),
  th: words('colspan rowspan headers scope align valign width abbr'),
  col: words('span width'),
  colgroup: words('span width'),
  table: words('border cellpadding cellspacing width align'),
  ol: words('start type reversed'),
  ul: words('type'),
  li: words('value'),
  details: words('open'),
  input: words('type checked disabled name value readonly placeholder'),
  button: words('type disabled name value'),
  form: words('method name'),
  label: words('for'),
  fieldset: words('disabled name'),
  time: words('datetime'),
  data: words('value'),
  q: words('cite'),
  blockquote: words('cite'),
  del: words('cite datetime'),
  ins: words('cite datetime'),
  bdo: words('dir'),
  meter: words('value min max low high optimum'),
  progress: words('value max'),
  output: words('for name'),
  font: words('color size face'),
  hr: words('width align'),
  pre: words('width'),
  div: words('align'),
  p: words('align'),
};
const URL_ATTRS = new Set(['href', 'src', 'cite']);
const SVG_ATTRS = words(`xmlns viewBox width height preserveAspectRatio version x y x1 y1 x2 y2 cx cy r rx ry d fill stroke stroke-width stroke-linecap stroke-linejoin
  stroke-dasharray stroke-dashoffset stroke-miterlimit stroke-opacity fill-opacity fill-rule clip-rule opacity transform points offset stop-color stop-opacity
  gradientUnits gradientTransform spreadMethod patternUnits patternTransform clipPathUnits markerWidth markerHeight refX refY orient font-size font-family
  font-weight text-anchor dx dy aria-hidden focusable`);
const MATH_ATTRS = words(`xmlns display mathvariant mathsize mathcolor mathbackground displaystyle scriptlevel stretchy fence separator lspace rspace accent accentunder
  columnalign rowalign columnspacing rowspacing columnlines rowlines frame width height depth voffset linethickness notation form symmetric largeop movablelimits
  minsize maxsize columnspan rowspan encoding`);

const SCHEMES = new Set(['http', 'https', 'mailto', 'tel', 'ftp']);
const DATA_IMAGE = /^data:image\/(?:png|jpe?g|gif|webp|avif|bmp|x-icon|svg\+xml)[;,]/;

/** Whether a URL (already entity-decoded, as the parser hands it over) may stay. Whitespace and control characters are removed first,
 *  and more than a browser removes, so a scheme hidden behind one is still seen (`java\tscript:`, a leading `\u0001`). No scheme
 *  (relative, `#frag`, `//host`) is fine. `data:` only for an image source. */
export function safeUrl(value: string, attr: string): boolean {
  const url = value.replace(/[\u0000-\u0020\u007f-\u009f\u00ad\u200b-\u200f\u2028\u2029\u2060\ufeff]/g, '').toLowerCase();
  const scheme = /^([a-z][a-z0-9+.-]*):/.exec(url)?.[1];
  if (scheme === undefined) return true;
  if (SCHEMES.has(scheme)) return true;
  return scheme === 'data' && attr === 'src' && DATA_IMAGE.test(url);
}

// CSS: `@import` and `url(...)` to anything but the web or an inline image go. CSS escapes can hide both (`\\40 import`, `u\\72l(`), so
// the result is also checked in its decoded form and dropped altogether if anything is left to remove there.
function stripCss(css: string): string {
  return css
    .replace(/\/\*[\s\S]*?(?:\*\/|$)/g, '')
    .replace(/@import\b[^;{]*;?/gi, '')
    .replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|((?:[^()\\]|\\.|\([^)]*\))*))\s*\)/gi, (whole, a: string | undefined, b: string | undefined, c: string | undefined) => {
      const target = (a ?? b ?? c ?? '').trim();
      return target === '' || safeUrl(target, 'src') ? whole : 'url()';
    })
    .replace(/expression\s*\(|-moz-binding|behavior\s*:/gi, 'x(');
}
const decodeCssEscapes = (css: string): string =>
  css.replace(/\\(?:([0-9a-fA-F]{1,6})[ \t\n\r\f]?|([\s\S]))/g, (_, hex: string | undefined, ch: string | undefined) => (hex ? String.fromCodePoint(Math.min(parseInt(hex, 16) || 0xfffd, 0x10ffff)) : ch!));
export function cleanCss(css: string): string {
  const out = stripCss(css);
  return out.includes('\\') && stripCss(decodeCssEscapes(out)) !== decodeCssEscapes(out) ? '' : out;
}

function attrAllowed(space: string, tag: string, name: string, value: string): string | null {
  const prefixed = /^(?:data|aria)-[a-z0-9_.:-]+$/.test(name); // the only open-ended names, so the only ones checked for shape
  const global = prefixed || (space === ns.NS.HTML && GLOBAL_ATTRS.has(name));
  if (space === ns.NS.HTML) {
    if (!global && !HTML_ATTRS[tag]?.has(name)) return null;
    if (name === 'style') return cleanCss(value);
    if (URL_ATTRS.has(name) && !safeUrl(value, name)) return null;
    if (tag === 'input' && name === 'type' && !/^(?:checkbox|radio|text|number|range|date|time|email|search|tel|url|password|hidden|button|submit|reset)$/i.test(value)) return null;
    return value;
  }
  const ok = prefixed || name === 'class' || name === 'id' || name === 'role' || name === 'lang' || name === 'style'
    || (space === ns.NS.SVG ? SVG_ATTRS.has(name) : MATH_ATTRS.has(name));
  if (!ok) return null;
  if (name === 'style') return cleanCss(value);
  if (/^(?:fill|stroke|stop-color)$/.test(name) && /url\s*\(/i.test(value) && !/^url\(\s*#[^)]*\)$/i.test(value.trim())) return null;
  return value;
}

function cleanChildren(parent: { childNodes: Child[] }): Child[] {
  const out: Child[] = [];
  for (const node of parent.childNodes) {
    if (defaultTreeAdapter.isTextNode(node)) out.push(node);
    else if (defaultTreeAdapter.isElementNode(node)) out.push(...cleanElement(node));
    // comments, doctypes, processing instructions: dropped
  }
  return out;
}

/** The nodes `el` becomes: itself cleaned, its cleaned children (unwrapped), or nothing. */
function cleanElement(el: El): Child[] {
  const space = el.namespaceURI;
  const tag = el.tagName; // SVG names keep their case (`clipPath`); HTML ones are lower case
  const known = space === ns.NS.HTML ? HTML_TAGS.has(tag) : space === ns.NS.SVG ? SVG_TAGS.has(tag) : space === ns.NS.MATHML ? MATH_TAGS.has(tag) : false;
  if (!known) {
    // Foreign elements that are not on the list (<style>, <script>, <foreignObject>, <annotation-xml>, <mglyph>, ...) and HTML ones on
    // the drop list go with their content; any other HTML element is replaced by its cleaned children, never by itself.
    return space === ns.NS.HTML && !DROP_WITH_CONTENT.has(tag) ? cleanChildren(el) : [];
  }
  const attrs: El['attrs'] = [];
  for (const attr of el.attrs) {
    // `xmlns` on <svg>/<math> only, and only with the namespace the element is in anyway. xlink:href, xml:lang, xmlns:*: not needed,
    // and href through them is a script URL.
    if (attr.name === 'xmlns' && !attr.prefix && attr.value === space && space !== ns.NS.HTML) {
      attrs.push({ name: 'xmlns', value: attr.value });
      continue;
    }
    if (attr.namespace || attr.prefix) continue;
    const value = attrAllowed(space, tag, attr.name, attr.value);
    if (value !== null) attrs.push({ name: attr.name, value });
  }
  el.attrs = attrs;
  if (space === ns.NS.HTML && tag === 'style') {
    for (const child of el.childNodes) if (defaultTreeAdapter.isTextNode(child)) child.value = cleanCss(child.value);
    el.childNodes = el.childNodes.filter((child) => defaultTreeAdapter.isTextNode(child));
    return [el];
  }
  el.childNodes = cleanChildren(el);
  return [el];
}

function pass(html: string): string {
  const context = defaultTreeAdapter.createElement('div', ns.NS.HTML, []);
  const fragment = parseFragment(context, html, {});
  fragment.childNodes = cleanChildren(fragment);
  return serialize(fragment);
}

const escapeText = (s: string): string => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function sanitizeHtml(html: string): string {
  if (!html.includes('<') && !html.includes('&')) return html;
  let current = html;
  for (let i = 0; i < 4; i++) {
    const next = pass(current);
    if (next === current) return next;
    current = next;
  }
  return escapeText(html); // never settled: not markup we can vouch for, so it is shown as text
}

