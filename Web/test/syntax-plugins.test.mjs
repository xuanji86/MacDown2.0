// GitHub alerts, emoji short codes, `[X]` task items, Hugo `+++` TOML front matter.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
import { splitBlocks, alignSegments } from '../src/preview/split-html.ts';

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
const without = (...names) => ({ ...base, extensions: ALL.filter((e) => !names.includes(e)) });
const html = (src, o = base) => renderResult(src, o).html.replace(/ data-line(?:-end)?="\d+"/g, '').trim();

// ---- GitHub alerts ------------------------------------------------------------------------------------------------

test('alerts: the five GitHub kinds, titled like GitHub', () => {
  for (const [marker, kind, title] of [['NOTE', 'note', 'Note'], ['TIP', 'tip', 'Tip'], ['IMPORTANT', 'important', 'Important'], ['WARNING', 'warning', 'Warning'], ['CAUTION', 'caution', 'Caution']]) {
    assert.equal(
      html(`> [!${marker}]\n> Useful *information*.\n> Second line.`),
      `<div class="markdown-alert markdown-alert-${kind}">\n<p class="markdown-alert-title">${title}</p>\n<p>Useful <em>information</em>.\nSecond line.</p>\n</div>`,
      marker,
    );
  }
  assert.match(html('> [!note]\n> lower case marker'), /<p class="markdown-alert-title">Note<\/p>/);
  assert.match(html('> [!Warning]\n> mixed case marker'), /<p class="markdown-alert-title">Warning<\/p>/);
});

test('alerts: anything that is not exactly the GitHub form stays an ordinary blockquote', () => {
  for (const plain of ['> [!QUESTION]\n> not a GitHub kind', '> [!NOTE] with text on the marker line\n> body', '> [!NOTE]', '> text\n> [!NOTE]\n> not first', '> normal quote']) {
    assert.doesNotMatch(html(plain), /markdown-alert/, plain);
    assert.match(html(plain), /<blockquote>/, plain);
  }
});

test('alerts: blocks inside, and the block range includes the marker line (scroll sync, patch hash)', () => {
  const md = 'before\n\n> [!TIP]\n> - one\n> - two\n>\n> ```js\n> let a;\n> ```\n\nafter';
  const r = renderResult(md, base);
  const stripped = r.html.replace(/ data-line(?:-end)?="\d+"/g, '');
  assert.match(stripped, /<div class="markdown-alert markdown-alert-tip">\n<p class="markdown-alert-title">Tip<\/p>\n<ul>\n<li>one<\/li>\n<li>two<\/li>\n<\/ul>\n<pre/);
  assert.deepEqual(r.blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 9], [10, 11]]);
  assert.match(r.html, /<div class="markdown-alert markdown-alert-tip" data-line="2" data-line-end="9">/);
  // editing only the marker line must change the block, or the preview would keep the old one
  const other = renderResult(md.replace('[!TIP]', '[!NOTE]'), base);
  assert.notEqual(r.blocks[1].hash, other.blocks[1].hash);
  // and the preview can still cut the page into the renderer's blocks
  assert.equal(alignSegments(r.html, splitBlocks(r.html), r.blocks.length)?.length, r.blocks.length);
});

test('alerts: neighbouring and nested quotes are untouched', () => {
  const out = html('> plain\n\n> [!NOTE]\n> alert\n>\n> > nested quote\n\n> plain again');
  assert.equal((out.match(/<blockquote>/g) ?? []).length, 3); // plain, nested, plain again
  assert.equal((out.match(/markdown-alert-note/g) ?? []).length, 1);
});

// ---- emoji --------------------------------------------------------------------------------------------------------

const emoji = { ...base, extensions: [...ALL, 'emoji'] };

test('emoji: short codes only when switched on', () => {
  assert.equal(html('Hi :smile: and :+1: and :tada:'), '<p>Hi :smile: and :+1: and :tada:</p>'); // off by default
  assert.equal(html('Hi :smile: and :+1: and :tada:', emoji), '<p>Hi 😄 and 👍 and 🎉</p>');
  assert.equal(html('x:heart:y :nosuchemoji: 10:30:45', emoji), '<p>x❤️y :nosuchemoji: 10:30:45</p>');
});

test('emoji: not in code, not for smileys; headings, links and autolinks keep working', () => {
  assert.equal(html('`:smile:` and :-) :) :D', emoji), '<p><code>:smile:</code> and :-) :) :D</p>');
  assert.equal(html('```\n:smile:\n```', emoji), '<pre><code>:smile:\n</code></pre>');
  assert.match(html('# Done :white_check_mark:', emoji), /<h1 id="[^"]*">Done ✅<\/h1>/);
  assert.equal(html('[link :rocket:](https://example.com/:smile:)', emoji), '<p><a href="https://example.com/:smile:">link 🚀</a></p>');
  assert.equal(html('see https://example.com/a:smile:b', emoji), '<p>see <a href="https://example.com/a:smile:b">https://example.com/a:smile:b</a></p>');
});

test('emoji: the other renderer instance is not affected', () => {
  assert.equal(html(':smile:', emoji), '<p>😄</p>');
  assert.equal(html(':smile:'), '<p>:smile:</p>');
  assert.equal(html(':smile:', emoji), '<p>😄</p>');
});

// ---- task items ---------------------------------------------------------------------------------------------------

test('task lists: [X] and [x] are both checked, [ ] is open, anything else is text', () => {
  const out = html('- [X] upper\n- [x] lower\n- [ ] open\n- [Y] neither');
  assert.equal((out.match(/checked="checked"/g) ?? []).length, 2);
  assert.equal((out.match(/class="task-list-item-checkbox"/g) ?? []).length, 3);
  assert.match(out, /\[Y\] neither/);
  assert.match(html('1. [X] numbered'), /checked="checked"/);
});

// ---- Hugo +++ front matter ----------------------------------------------------------------------------------------

test('front matter: Hugo +++ TOML is recognised, hidden by default, a table on request', () => {
  const src = '+++\ntitle = "Hi"\ndraft = false\ntags = ["a", "b"]\ndate = 2024-05-01\n\n[params]\nauthor = "Me"\n+++\n\n# Body\n';
  const hidden = renderResult(src, base);
  assert.equal(hidden.frontMatter, 'title = "Hi"\ndraft = false\ntags = ["a", "b"]\ndate = 2024-05-01\n\n[params]\nauthor = "Me"');
  assert.match(hidden.html, /^<div class="front-matter" hidden data-line="0" data-line-end="9"><\/div>\n<h1 data-line="10"/);
  assert.deepEqual(hidden.blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 9], [10, 11]]);
  assert.equal(hidden.outline.length, 1);
  const table = renderResult(src, { ...base, frontMatterDisplay: 'table' }).html;
  assert.match(
    table,
    /<table class="front-matter"[^>]*><tbody><tr><th>title<\/th><td>Hi<\/td><\/tr><tr><th>draft<\/th><td>false<\/td><\/tr><tr><th>tags<\/th><td>\[&quot;a&quot;,&quot;b&quot;\]<\/td><\/tr><tr><th>date<\/th><td>2024-05-01<\/td><\/tr><tr><th>params<\/th><td>\{&quot;author&quot;:&quot;Me&quot;\}<\/td><\/tr><\/tbody><\/table>/,
  );
});

test('front matter: +++ edge cases', () => {
  const table = { ...base, frontMatterDisplay: 'table' };
  assert.equal(renderResult('+++\ntitle = "x"\n\n# never closed\n', base).frontMatter, undefined); // an unclosed fence is text
  assert.match(html('+++\ntitle = "x"\n\n# never closed\n'), /<p>\+\+\+/);
  assert.equal(renderResult('# T\n\n+++\ntitle = "x"\n+++\n', base).frontMatter, undefined); // only at the very top
  assert.equal(renderResult('+++ \ntitle = "x"\n+++ \n', base).frontMatter, 'title = "x"'); // trailing spaces on the fences
  assert.equal(renderResult('++++\ntitle = "x"\n++++\n', base).frontMatter, undefined); // four plus signs is not the fence
  const bad = renderResult('+++\ntitle = \n+++\n', table);
  assert.match(bad.html, /<pre class="front-matter"[^>]*><code>title = <\/code><\/pre>/); // unparsable: the source, as for YAML
  assert.equal(bad.frontMatter, 'title = ');
  assert.equal(renderResult('+++\n+++\n\ntext', base).frontMatter, '');
  assert.equal(renderResult('+++\ntitle = "x"\n+++\n', without('frontMatter')).frontMatter, undefined);
  assert.match(html('+++\ntitle = "x"\n+++\n', without('frontMatter')), /\+\+\+/);
  assert.doesNotMatch(renderResult('+++\ntitle = "secret"\n+++\n', base).html, /secret/);
  assert.equal(renderResult('---\ntitle: y\n---\n', base).frontMatter, 'title: y'); // YAML next to it is unchanged
});
