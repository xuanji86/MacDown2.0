// The quarto flavor (quarto.chunk.js): one case per syntax, the include limits, escaping, block mapping for the preview,
// and snapshots of the official example documents in test/fixtures/quarto (see its README).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { build } from 'esbuild';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { alignSegments, splitBlocks } from '../src/preview/split-html.ts';
import { ALL_EXTENSIONS, chunkSource, loadQuarto, plain, quartoOptions } from './helpers/quarto.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const { renderResult, flavors } = await loadQuarto();
const html = (src, over) => plain(renderResult(src, quartoOptions(over)).html);

test('the flavor registers itself with the main bundle', () => {
  assert.ok(flavors.has('quarto'));
  assert.throws(() => renderResult('x', quartoOptions({ flavor: 'nope' })), /Unknown flavor/);
});

test('the main bundle contains no Quarto code', async () => {
  const main = (await build({ entryPoints: [join(here, '../src/render/index.ts')], bundle: true, write: false, format: 'iife', globalName: 'MacDown2', minify: true, tsconfigRaw: '{}', logLevel: 'silent' })).outputFiles[0].text;
  for (const marker of ['quarto_callout', 'pandoc_div', 'curly_attributes', 'quarto-', 'quarto_include']) assert.ok(!main.includes(marker), marker);
  assert.ok((await chunkSource()).length <= 120 * 1024, 'chunk over its 120 KB budget');
});

// --- vendored plugins, one per syntax ---------------------------------------------------------------------

test('callouts: heading title, title attribute, default title, body without a heading', () => {
  const out = html('::: {.callout-note}\n## My title\n\nBody\n:::\n\n::: {.callout-warning title="Heads up"}\nWarning body.\n:::\n\n::: callout-tip\nTip\n:::');
  assert.match(out, /<div  class="callout callout-note callout-style-default">/);
  assert.match(out, /callout-title-container">\nMy title<\/div>/);
  assert.match(out, /callout-warning[^>]*>[\s\S]*Heads up\n[\s\S]*<div class="callout-body-container callout-body"><p>Warning body\.<\/p>/);
  assert.match(out, /callout-title-container">Tip\n/);
});

test('divs: nested and attributes; an unclosed div is closed at the end of the document', () => {
  const out = html('::: {#outer .a key=v}\ntext\n\n::: inner\nx\n:::\n\n:::\n\n::: {.open}\nnever closed\n\nfootnote[^1]\n\n[^1]: note');
  assert.match(out, /<div  id="outer" class="a quarto-div" key="v"><p>text<\/p>\n<div  class="inner quarto-div"><p>x<\/p>\n<\/div><\/div>/);
  assert.match(out, /<div  class="open quarto-div"><p>never closed<\/p>[\s\S]*<\/div><hr class="footnotes-sep">/); // closed before the footnotes
});

test('spans: [text]{.class #id}', () => {
  assert.match(html('a [span]{.mark #sp key="v"} b'), /<span class="mark" id="sp" key="v">span<\/span>/);
});

test('cites and cross-references', () => {
  const out = html('See @knuth84 and [@doe99] and @fig-plot, @tbl-x, @sec-intro, @eq-m.');
  assert.match(out, /<code  class="cite in-text">@knuth84<\/code>/);
  assert.match(out, /<a class="quarto-xref" href="#fig-plot">Figure \?<\/a>/);
  assert.match(out, /href="#tbl-x">Table \?<\/a>/);
  assert.match(out, /href="#sec-intro">Section \?<\/a>/);
  assert.match(out, /href="#eq-m">Equation \?<\/a>/);
});

test('figures: image with caption becomes figure + figcaption; ids stay on the image', () => {
  const out = html('![A caption](a.png){#fig-a width=50%}\n\n![](no-caption.png)');
  assert.match(out, /<figure><img src="a.png" alt="" id="fig-a" width="50%"><figcaption>A caption<\/figcaption><\/figure>/);
  assert.match(out, /<p><img src="no-caption.png" alt=""><\/p>/);
});

test('figure divs: ::: {#fig-x} with a trailing caption paragraph', () => {
  const out = html('::: {#fig-x}\n![](a.png)\n\nThe caption\n:::');
  assert.match(out, /<figure id="fig-x">[\s\S]*<figcaption>The caption<\/figcaption>\s*<\/figure>/);
});

test('table captions: ": caption {#tbl-x}" moves into the table', () => {
  const out = html('| a | b |\n|---|---|\n| 1 | 2 |\n\n: The table {#tbl-x}');
  assert.match(out, /<table id="tbl-x">\n<caption>The table<\/caption>/);
  assert.doesNotMatch(out, /<p>: /);
});

test('gridtables', () => {
  const out = html('+-----+-----+\n| Col | Two |\n+=====+=====+\n| a   | b   |\n+-----+-----+');
  assert.match(out, /<table>[\s\S]*<th>Col<\/th>[\s\S]*<td>a<\/td>/);
});

test('math: Pandoc dollars through KaTeX, labelled display equations get their id; off with the math option', () => {
  const out = html('Inline $a < b$ and prices $5 or $10.\n\n$$\nE = mc^2\n$$ {#eq-mass}');
  assert.match(out, /Inline <span class="katex">/);
  assert.match(out, /<p id="eq-mass" class='katex-block'>/);
  const off = html('Inline $a < b$.', { extensions: ALL_EXTENSIONS.filter((e) => e !== 'math') });
  assert.doesNotMatch(off, /katex/);
});

test('shortcodes render as inert, escaped markers', () => {
  assert.equal(html('{{< var foo "<b>" >}}'), '<p><span class="shortcode">{{&lt; var foo &quot;&lt;b&gt;&quot; &gt;}}</span></p>');
});

test('yaml: title block with title, author, date, abstract and the remaining options', () => {
  const out = html('---\ntitle: "T & U"\nauthor: Ada\ndate: 2026-10-03\nabstract: Short.\nformat: html\n---\n\ntext');
  assert.match(out, /<div class="quarto-title-block"><h1>T &amp; U<\/h1>/);
  assert.match(out, /quarto-meta-title">Author<\/p>\n<p>Ada<\/p>/);
  assert.match(out, /quarto-meta-title">Date<\/p>\n<p>2026-10-03<\/p>/);
  assert.match(out, /<p class="quarto-abstract">Short\.<\/p>/);
  assert.match(out, /<code class="cm-s-jupyter language-yaml quarto-frontmatter">format: html\n<\/code>/);
});

// --- code cells -----------------------------------------------------------------------------------------

test('code-cell: header with language, #| options table, highlighted code; never executed', () => {
  const out = html('```{python}\n#| label: fig-plot\n#| echo: false\n#| fig-cap: "A plot"\nprint("hi")\n```');
  assert.match(out, /<div class="quarto-cell" data-lang="python" id="fig-plot">/);
  assert.match(out, /quarto-cell-lang">python<\/span><span class="quarto-cell-note">code cell · not executed<\/span>/);
  assert.match(out, /<tr><th>echo<\/th><td>false<\/td><\/tr>/);
  assert.match(out, /<tr><th>fig-cap<\/th><td>A plot<\/td><\/tr>/);
  assert.match(out, /<pre data-lang="python"><code class="hljs language-python"><span class="hljs-built_in">print<\/span>/);
  assert.doesNotMatch(out, /#\|/); // option lines are not part of the code view
});

test('code-cell: variants (r with attributes, {.python} plain code, cell without options, escaped {{r}})', () => {
  assert.match(html('```{r eval=1+1=2}\nx <- 1\n```'), /data-lang="r"[\s\S]*hljs language-r/);
  const plainCode = html('```{.python filename="a.py"}\nprint(1)\n```');
  assert.match(plainCode, /^<pre data-lang="python"><code class="hljs language-python">/);
  assert.doesNotMatch(html('```{python}\n1\n```'), /quarto-cell-options/);
  assert.match(html('```{{r}}\n1 + 1\n```'), /^<pre data-lang="\{\{r\}\}">/); // Quarto's way to show a cell literally
  assert.match(html('```{python}\n#| echo: [unterminated\nx = 1\n```'), /<tr><th><\/th><td>echo: \[unterminated<\/td><\/tr>/); // not YAML: lines as they are
});

test('code-cell: option values are escaped', () => {
  assert.match(html('```{r}\n#| fig-cap: "<img src=x onerror=alert(1)>"\n1\n```'), /<td>&lt;img src=x onerror=alert\(1\)&gt;<\/td>/);
});

test('inline cells get a language marker; ordinary code is untouched', () => {
  const out = html('Mean `{python} df.x.mean()`, `r 1 + 1`, plain `r`, `x` and `print(1)`.');
  assert.match(out, /<code class="inline-cell" data-lang="python">df\.x\.mean\(\)<\/code>/);
  assert.match(out, /<code class="inline-cell" data-lang="r">1 \+ 1<\/code>/);
  assert.match(out, /plain <code>r<\/code>, <code>x<\/code> and <code>print\(1\)<\/code>/);
});

// --- include ------------------------------------------------------------------------------------------

const files = {
  'a.qmd': '## From A\n\nA text\n',
  'sub/b.qmd': 'B text\n\n{{< include c.qmd >}}\n',
  'sub/c.qmd': 'C text',
  'loop1.qmd': 'one\n\n{{< include loop2.qmd >}}',
  'loop2.qmd': 'two\n\n{{< include loop1.qmd >}}',
  'self.qmd': '{{< include self.qmd >}}',
  'front.qmd': '---\ntitle: ignored\n---\n\nbody',
  'unclosed.qmd': '::: {.callout-note}\ninside',
  'l1.qmd': '{{< include l2.qmd >}}', 'l2.qmd': '{{< include l3.qmd >}}', 'l3.qmd': '{{< include l4.qmd >}}',
  'l4.qmd': '{{< include l5.qmd >}}', 'l5.qmd': '{{< include l6.qmd >}}', 'l6.qmd': 'too deep',
};
const withFiles = (src) => html(src, { files });

test('include: inlines the file in one wrapper block, headings join the outline, nested relative to the including file', () => {
  const res = renderResult('# Main\n\n{{< include a.qmd >}}\n\n{{< include "sub/b.qmd" >}}\n\nend', quartoOptions({ files }));
  const out = plain(res.html);
  assert.match(out, /<div class="quarto-include" data-include="a.qmd">\n<h2 id="from-a">From A<\/h2>\n<p>A text<\/p>\n<\/div>/);
  assert.match(out, /data-include="sub\/b.qmd">\n<p>B text<\/p>\n<div class="quarto-include" data-include="sub\/c.qmd">\n<p>C text<\/p>/);
  assert.deepEqual(res.blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 3], [4, 5], [6, 7]]);
  assert.deepEqual(res.outline.map((o) => [o.text, o.line]), [['Main', 0], ['From A', 2]]);
  assert.ok(alignSegments(res.html, splitBlocks(res.html), res.blocks.length));
});

test('include: front matter of the included file is dropped, an unclosed div stays inside it', () => {
  assert.equal(withFiles('{{< include front.qmd >}}\n\nafter'), '<div class="quarto-include" data-include="front.qmd">\n<p>body</p>\n</div>\n<p>after</p>');
  assert.match(withFiles('{{< include unclosed.qmd >}}\n\nafter'), /<\/div><\/div><\/div>\n<p>after<\/p>/);
});

test('include: paths outside the document folder are refused', () => {
  for (const path of ['../x.qmd', 'sub/../../x.qmd', '/etc/passwd', 'file:///etc/passwd', 'https://example.com/a.qmd', '..', '.']) {
    const out = withFiles(`{{< include ${path} >}}`);
    assert.match(out, /quarto-include-error">include <code>[^<]*<\/code>: outside the document folder</, path);
  }
  // a smuggled entry in the map is not enough: only resolved, in-folder paths are looked up
  assert.match(html('{{< include ../secret.qmd >}}', { files: { '../secret.qmd': 'leak', 'secret.qmd': 'leak' } }), /outside the document folder/);
  assert.match(withFiles('{{< include sub/../a.qmd >}}'), /data-include="a.qmd"/); // staying inside is fine
});

test('include: cycles and runaway depth are refused, missing files are reported', () => {
  assert.match(withFiles('{{< include loop1.qmd >}}'), /data-include="loop2.qmd">[\s\S]*include <code>loop1.qmd<\/code>: circular include/);
  assert.match(withFiles('{{< include self.qmd >}}'), /data-include="self.qmd">\n<div class="quarto-include quarto-include-error">include <code>self.qmd<\/code>: circular include/);
  const deep = withFiles('{{< include l1.qmd >}}');
  assert.match(deep, /data-include="l5.qmd"/);
  assert.match(deep, /include <code>l6.qmd<\/code>: more than 5 levels deep/);
  assert.doesNotMatch(deep, /too deep/);
  assert.match(withFiles('{{< include nope.qmd >}}'), /include <code>nope.qmd<\/code>: not found/);
  assert.match(html('{{< include a.qmd >}}'), /: not found/); // no files handed over (Quick Look)
});

test('include: only on a line of its own; elsewhere it is an ordinary shortcode', () => {
  assert.match(withFiles('text {{< include a.qmd >}} more'), /<span class="shortcode">/);
  assert.match(withFiles('```\n{{< include a.qmd >}}\n```'), /<pre><code>\{\{&lt; include a.qmd &gt;\}\}/);
});

// --- escaping -------------------------------------------------------------------------------------------

test('document text is escaped where vendored code interpolates it', () => {
  assert.doesNotMatch(html('::: {.callout-note title="<img src=x onerror=1>"}\nx\n:::'), /<img src=x/);
  assert.doesNotMatch(html('@a<img'), /<img/);
  assert.doesNotMatch(html('---\ntitle: <script>x</script>\nauthor: <b>n</b>\nfoo: <i>\n---\n'), /<script>|<b>|<i>/);
});

test('attribute blocks cannot set event handlers or URLs', () => {
  const out = html('[x]{onclick="a()" href="javascript:a()" .ok}\n\n![i](a.png){onerror="a()" src="b.png" width=10}');
  assert.doesNotMatch(out, /onclick|onerror|javascript:|src="b.png"/);
  assert.match(out, /class="ok"/);
  assert.match(out, /width="10"/);
});

test('explicit heading ids win over generated slugs and reach the outline', () => {
  const res = renderResult('# Intro {#sec-intro}\n\n## Other', quartoOptions());
  assert.match(res.html, /<h1 id="sec-intro" data-line="0" data-line-end="1">/);
  assert.deepEqual(res.outline.map((o) => o.slug), ['sec-intro', 'other']);
});

// --- fixtures ---------------------------------------------------------------------------------------------

const fixtures = join(here, 'fixtures/quarto');
const names = readdirSync(fixtures).filter((f) => f.endsWith('.qmd')).sort();
const snapshots = join(here, 'snapshots/quarto');

test('official examples are present', () => assert.ok(names.length >= 5));

for (const name of names) {
  test(`example ${name}: renders without error, matches its snapshot, stays block-patchable`, () => {
    const res = renderResult(readFileSync(join(fixtures, name), 'utf8'), quartoOptions({ codeLineNumbers: true, frontMatterDisplay: 'table' }));
    const file = join(snapshots, name.replace(/\.qmd$/, '.html'));
    if (process.env.SNAPSHOT_UPDATE === '1') {
      mkdirSync(snapshots, { recursive: true });
      writeFileSync(file, res.html);
    } else {
      assert.ok(existsSync(file), `missing snapshot ${file}; run SNAPSHOT_UPDATE=1 npm test`);
      assert.equal(res.html, readFileSync(file, 'utf8'));
    }
    // raw HTML that is not balanced per block (<!doctype>, <details>) makes the page rebuild instead of patch; that is
    // true of plain Markdown too, so only documents without it must align
    if (!/<!doctype|<details/i.test(res.html)) assert.ok(alignSegments(res.html, splitBlocks(res.html), res.blocks.length), 'blocks do not line up with the HTML');
  });
}

test('the same examples render as plain Markdown when the flavor is not loaded (extension off)', () => {
  const src = readFileSync(join(fixtures, 'quarto-syntax.qmd'), 'utf8');
  const out = renderResult(src, quartoOptions({ flavor: 'markdown', renderChunks: [] })).html;
  assert.doesNotMatch(out, /class="[^"]*(callout|quarto-)/);
});
