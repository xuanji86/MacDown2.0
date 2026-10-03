// One positive and one negative case per syntax extension, plus the CJK-friendly emphasis edge cases.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
import { wrapLines } from '../src/render/plugins/code.ts';
import { tocList } from '../src/render/plugins/toc.ts';

const ALL = ['tables', 'strikethrough', 'autolink', 'mark', 'sup', 'sub', 'underline', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'];
const base = {
  flavor: 'markdown',
  extensions: ALL,
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
};
const dollars = { ...base, inlineDollarMath: true };
const without = (...names) => ({ ...base, extensions: ALL.filter((e) => !names.includes(e)) });
const html = (src, o = base) => renderResult(src, o).html.replace(/ data-line(?:-end)?="\d+"/g, '').trim();

test('mark: ==x== becomes <mark>', () => {
  assert.equal(html('a ==b== c'), '<p>a <mark>b</mark> c</p>');
  assert.equal(html('a == b == c'), '<p>a == b == c</p>');
  assert.equal(html('a ==b== c', without('mark')), '<p>a ==b== c</p>');
});

test('sup and sub', () => {
  assert.equal(html('x^2^ H~2~O'), '<p>x<sup>2</sup> H<sub>2</sub>O</p>');
  assert.equal(html('x^a b^ H~a b~O'), '<p>x^a b^ H~a b~O</p>');
  assert.equal(html('x^2^ H~2~O', without('sup', 'sub')), '<p>x^2^ H~2~O</p>');
  assert.match(html('~~gone~~ and H~2~O'), /<s>gone<\/s> and H<sub>2<\/sub>O/); // strikethrough keeps working
});

test('footnotes', () => {
  const out = html('Text[^1].\n\n[^1]: The note.\n');
  assert.match(out, /<sup class="footnote-ref"><a href="#footnote1">\[1\]<\/a>/);
  assert.match(out, /<li id="footnote1" class="footnote-item"><p>The note\./);
  assert.doesNotMatch(html('Text[^1].\n\n[^1]: The note.\n', without('footnotes')), /footnote-ref/);
  assert.doesNotMatch(html('Text[^2].'), /footnote/); // no definition: stays text
});

test('task lists', () => {
  const out = html('- [x] done\n- [ ] todo\n- [y] nope');
  assert.match(out, /<input type="checkbox" class="task-list-item-checkbox" id="task-item-0" checked="checked" disabled="disabled">/);
  assert.match(out, /id="task-item-1" disabled="disabled">/);
  assert.match(out, />\[y\] nope<\/li>/); // not a task marker
  assert.doesNotMatch(html('- [x] done', without('taskLists')), /<input/);
});

test('underline: only _x_ becomes <u>', () => {
  const u = { ...base, extensions: [...ALL] };
  assert.equal(html('_u_ *e* __s__ **s**', u), '<p><u>u</u> <em>e</em> <strong>s</strong> <strong>s</strong></p>');
  assert.equal(html('_u_ *e*', without('underline')), '<p><em>u</em> <em>e</em></p>');
  assert.equal(html('snake_case_word', u), '<p>snake_case_word</p>');
  assert.equal(html('_a *b* c_', u), '<p><u>a <em>b</em> c</u></p>');
});

test('toc: a lone [TOC] paragraph becomes a nested heading list', () => {
  const out = html('[TOC]\n\n# One\n\n## Two\n\n## Three\n\n# Four\n');
  assert.equal(
    out.split('\n')[0],
    '<nav class="toc"><ul><li><a href="#one">One</a><ul><li><a href="#two">Two</a></li><li><a href="#three">Three</a></li></ul></li><li><a href="#four">Four</a></li></ul></nav>',
  );
  assert.match(out, /<h1 id="one">One<\/h1>/);
  assert.match(html('[TOC]\n\n# One', { ...base, headingAnchors: false }), /<h1 id="one">/); // links need ids
  assert.doesNotMatch(html('# One', { ...base, headingAnchors: false }), /id=/);
  assert.equal(html('see [TOC] here\n\n# One'), '<p>see [TOC] here</p>\n<h1 id="one">One</h1>');
  assert.equal(html('[TOC]', without('toc')), '<p>[TOC]</p>');
  assert.equal(html('[TOC]'), '<nav class="toc"></nav>'); // no headings, no list
  assert.match(html('```\n[TOC]\n```\n# A'), /<pre[^>]*><code>\[TOC\]/);
});

test('tocList nests and closes level jumps', () => {
  const esc = (s) => s;
  const item = (level, text) => ({ level, text, slug: text, line: 0 });
  assert.equal(tocList([item(1, 'a'), item(3, 'b'), item(1, 'c')], esc), '<ul><li><a href="#a">a</a><ul><li><a href="#b">b</a></li></ul></li><li><a href="#c">c</a></li></ul>');
  assert.equal(tocList([], esc), '');
});

test('math: delimiters, modes and errors', () => {
  assert.match(html('inline $a_b$ end', dollars), /<span class="katex">/);
  assert.doesNotMatch(html('inline $a_b$ end'), /katex/); // inline `$…$` is off by default
  assert.match(html('$$\nx^2\n$$'), /<p class='katex-block'><span class="katex-display">/);
  assert.match(html('\\(x\\) and \\[y\\]'), /katex/);
  assert.match(html('\\(x\\)', dollars), /katex/);
  assert.doesNotMatch(html('$x$', without('math')), /katex/);
  assert.equal(html('costs $5 and $10'), '<p>costs $5 and $10</p>'); // currency is not math
  assert.equal(html('costs $5 and $10', dollars), '<p>costs $5 and $10</p>');
  assert.match(html('$x$', dollars), /katex/);
  assert.equal(html('`$x$`', dollars), '<p><code>$x$</code></p>');
  assert.doesNotThrow(() => html('$\\badcommand{x}$ and $$\\frac{$$', dollars)); // KaTeX errors render in place, never throw
  assert.match(html('$\\badcommand{x}$', dollars), /color:#cc0000/); // KaTeX's own red error rendering
});

test('math blocks keep data-line (one DOM node per block)', () => {
  const r = renderResult('para\n\n$$\nx^2\n$$\n\n\\[\ny\n\\]\n', base);
  assert.equal(r.html.match(/<p data-line="\d+" data-line-end="\d+" class='katex-block'>/g)?.length, 2);
  assert.deepEqual(r.blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 5], [6, 9]]);
});

test('math: \\gdef macros do not leak into the next render', () => {
  assert.doesNotMatch(html('$\\gdef\\foo{ZZ}\\foo$', dollars), /color:#cc0000/);
  assert.match(html('$\\foo$', dollars), /color:#cc0000/); // undefined again
});

test('math is parsed before emphasis', () => {
  const src = '$a*b$ and $c*d$ with _u_ $e_f$';
  const on = html(src, dollars);
  assert.doesNotMatch(on, /<em>/);
  assert.match(html('$a*b$ and $c*d$', { ...dollars, extensions: ALL.filter((e) => e !== 'math') }), /<em>b\$ and \$c<\/em>/); // proves the formula text would otherwise pair up
  assert.doesNotMatch(html('$$\na_1 * b_2\n$$', dollars), /<em>|<u>/);
  assert.match(html('$x_1$ and _u_', dollars), /<u>u<\/u>/);
});

test('front matter: hidden, table, raw, and not-at-top', () => {
  const src = '---\ntitle: Hi\ntags: [a, b]\ndraft: false\n---\n\n# Body\n';
  const hidden = renderResult(src, base);
  assert.equal(hidden.frontMatter, 'title: Hi\ntags: [a, b]\ndraft: false');
  assert.match(hidden.html, /^<div class="front-matter" hidden data-line="0" data-line-end="5"><\/div>\n<h1 data-line="6"/);
  assert.deepEqual(hidden.blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 5], [6, 7]]);
  assert.equal(hidden.outline.length, 1);
  const table = renderResult(src, { ...base, frontMatterDisplay: 'table' }).html;
  assert.match(table, /<table class="front-matter"[^>]*><tbody><tr><th>title<\/th><td>Hi<\/td><\/tr><tr><th>tags<\/th><td>\[&quot;a&quot;,&quot;b&quot;\]<\/td><\/tr><tr><th>draft<\/th><td>false<\/td><\/tr><\/tbody><\/table>/);
  const bad = renderResult('---\n: : [\n---\n', { ...base, frontMatterDisplay: 'table' });
  assert.match(bad.html, /<pre class="front-matter"[^>]*><code>: : \[<\/code><\/pre>/);
  assert.equal(bad.frontMatter, ': : [');
  assert.equal(renderResult('# T\n\n---\nnot: front\n---\n', base).frontMatter, undefined);
  assert.equal(renderResult(src, without('frontMatter')).frontMatter, undefined);
  assert.match(html(src, without('frontMatter')), /<hr>/);
  assert.doesNotMatch(renderResult(src, base).html, /title/);
});

test('code: highlight.js classes, language label, data-line on <pre>', () => {
  const out = renderResult('```js\nconst a = 1; // c\n```\n', base).html;
  assert.match(out, /^<pre data-line="0" data-line-end="3" data-lang="js"><code class="hljs language-js"><span class="hljs-keyword">const<\/span> a = <span class="hljs-number">1<\/span>; <span class="hljs-comment">\/\/ c<\/span>\n<\/code><\/pre>/);
  const off = html('```js\nconst a = 1;\n```', { ...base, codeHighlighting: false });
  assert.equal(off, '<pre data-lang="js"><code class="language-js">const a = 1;\n</code></pre>');
  assert.equal(html('```nosuchlang\n<b>\n```'), '<pre data-lang="nosuchlang"><code class="language-nosuchlang">&lt;b&gt;\n</code></pre>');
  assert.equal(html('```\n<b>\n```'), '<pre><code>&lt;b&gt;\n</code></pre>');
  assert.match(html('```py\nprint(1)\n```'), /hljs-built_in/); // alias of python
  assert.match(html('    indented\n'), /<pre><code>indented/); // indented blocks untouched
});

test('code: line numbers wrap every line and keep spans balanced', () => {
  const src = '```js\n/* a\n b */\nlet x;\n```\n';
  const out = html(src, { ...base, codeLineNumbers: true });
  assert.match(out, /^<pre data-lang="js" class="line-numbers">/);
  assert.equal(out.split('<span class="line">').length - 1, 3);
  const inner = out.slice(out.indexOf('<code'), out.indexOf('</code>'));
  assert.equal((inner.match(/<span/g) ?? []).length, (inner.match(/<\/span>/g) ?? []).length);
  assert.match(out, /<span class="line"><span class="hljs-comment">\/\* a<\/span><\/span>\n<span class="line"><span class="hljs-comment"> b \*\/<\/span><\/span>\n/);
  assert.equal(html('```\n```', { ...base, codeLineNumbers: true }), '<pre class="line-numbers"><code></code></pre>');
});

test('wrapLines', () => {
  assert.equal(wrapLines('a\nb\n'), '<span class="line">a</span>\n<span class="line">b</span>\n');
  assert.equal(wrapLines('<span class="x">a\nb</span>c'), '<span class="line"><span class="x">a</span></span>\n<span class="line"><span class="x">b</span>c</span>\n');
  assert.equal(wrapLines('a\n\nb'), '<span class="line">a</span>\n<span class="line"></span>\n<span class="line">b</span>\n');
});

// ---- CJK-friendly emphasis ----------------------------------------------------------------------
const cjkOn = (src) => html(src);
const cjkOff = (src) => html(src, without('cjkEmphasis'));

test('cjk emphasis: the motivating case, on and off', () => {
  assert.equal(cjkOn('**「重点」**的'), '<p><strong>「重点」</strong>的</p>');
  assert.equal(cjkOff('**「重点」**的'), '<p>**「重点」**的</p>');
});

test('cjk emphasis: punctuation kinds next to CJK (positive)', () => {
  for (const [src, want] of [
    ['这是**“重点”**文字', '<p>这是<strong>“重点”</strong>文字</p>'], // curly quotes
    ['这是**（重点）**文字', '<p>这是<strong>（重点）</strong>文字</p>'], // fullwidth parens
    ['**强调。**后文', '<p><strong>强调。</strong>后文</p>'], // ideographic full stop
    ['前文**(括号)**后文', '<p>前文<strong>(括号)</strong>后文</p>'], // ASCII punctuation
    ['日本語**「強調」**日本語', '<p>日本語<strong>「強調」</strong>日本語</p>'], // Japanese
    ['前文**「重点」**', '<p>前文<strong>「重点」</strong></p>'], // opener only needs CJK before it
    ['***「重点」***的', '<p><em><strong>「重点」</strong></em>的</p>'], // em + strong
    ['*「重点」*的', '<p><em>「重点」</em>的</p>'],
    ['~~「删」~~的', '<p><s>「删」</s>的</p>'], // strikethrough shares the same delimiter scan
    ['==「重点」==的', '<p><mark>「重点」</mark>的</p>'], // so does mark
    ['**"안녕"**하세요', '<p><strong>&quot;안녕&quot;</strong>하세요</p>'], // Hangul
    ['𠮷**「x」**𠮷', '<p>𠮷<strong>「x」</strong>𠮷</p>'], // astral-plane Han (surrogate pairs)
    ['ア**「ー」**ー', '<p>ア<strong>「ー」</strong>ー</p>'], // katakana + prolonged sound mark
  ]) {
    assert.equal(cjkOn(src), want, src);
    assert.notEqual(cjkOff(src), want, `${src} (must differ when off)`);
  }
});

test('cjk emphasis: cases that stay CommonMark (negative)', () => {
  for (const src of [
    'abc**「x」**def', // Latin letters on both sides
    'English**「中文」**English',
    '**中文。**English', // punctuation inside, Latin letter after
    '** 「x」**', // whitespace after opener
    '**「x」 **',
    '这是_「斜体」_的', // `_` keeps its intraword rule
    '这是_斜体_文字',
  ]) {
    assert.equal(cjkOn(src), cjkOff(src), src);
    assert.doesNotMatch(cjkOn(src), /<strong>|<em>/, src);
  }
});

test('cjk emphasis: unaffected behaviour', () => {
  for (const src of ['这是*斜体*文字', '**重点**：后文', '中文**English**中文', '**「重点」**，后文', '`**「x」**的`', '**bold** and *it*', 'a * b * c', '2 * 3 * 4']) {
    assert.equal(cjkOn(src), cjkOff(src), src);
  }
  assert.equal(cjkOn('这是*斜体*文字'), '<p>这是<em>斜体</em>文字</p>');
});

test('cjk emphasis: per-instance, other option sets are not affected', () => {
  assert.equal(cjkOn('**「重点」**的'), '<p><strong>「重点」</strong>的</p>');
  assert.equal(cjkOff('**「重点」**的'), '<p>**「重点」**的</p>'); // rendered after the "on" instance exists
  assert.equal(cjkOn('**「重点」**的'), '<p><strong>「重点」</strong>的</p>');
});
