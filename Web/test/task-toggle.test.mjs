// Task-list checkboxes in the preview (src/preview/tasks.ts). Static HTML (the renderer's output: Quick Look, export, print,
// `macdown2 render`) keeps them disabled; the live page enables them once the app has handed over its token, and a click
// only posts {token, line, checked, version} to the app: the page never edits anything itself. Page behaviour runs in
// headless Chrome with the app's message channel stubbed (window.__msgs); what the app does with the message is the
// Swift tests' business (TaskToggleTests, EditingViewTests).
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
import { chromeAvailable, launch } from './helpers/chrome.mjs';

const OPTIONS = {
  flavor: 'markdown',
  extensions: ['tables', 'strikethrough', 'autolink', 'mark', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
};
const optionsJSON = JSON.stringify(OPTIONS);

const DOC = [
  '- [ ] a', //                  0
  '- [x] b', //                  1
  '  - [ ] nested', //           2
  '', //                         3
  '> - [X] quoted', //           4
  '', //                         5
  '1. [ ] ordered', //           6
  '', //                         7
  '```', //                      8
  '- [ ] in a fence', //         9
  '```', //                      10
  '',
].join('\n');

describe('static HTML never becomes interactive', () => {
  test('the renderer keeps every checkbox disabled, whatever the item form', () => {
    const { html } = renderResult(DOC, OPTIONS);
    const boxes = html.match(/<input[^>]*task-list-item-checkbox[^>]*>/g) ?? [];
    assert.equal(boxes.length, 5); // the fenced one is code, not a task
    for (const box of boxes) assert.match(box, /\bdisabled="disabled"/);
  });
});

test('the renderer lists the checkboxes it made: the line the page reports and the line holding the mark', () => {
  assert.deepEqual(renderResult(DOC, OPTIONS).tasks, [
    { line: 0, mark: 0 },
    { line: 1, mark: 1 },
    { line: 2, mark: 2 },
    { line: 4, mark: 4 },
    { line: 6, mark: 6 },
  ]);
  // a loose item reports its paragraph's line; an item that starts with an empty bullet line has its mark one line below
  assert.deepEqual(renderResult('- [ ] a\n\n  more\n\n- [ ] b\n', OPTIONS).tasks, [{ line: 0, mark: 0 }, { line: 4, mark: 4 }]);
  assert.deepEqual(renderResult('-\n  [ ] b\n', OPTIONS).tasks, [{ line: 0, mark: 1 }]);
  assert.deepEqual(renderResult('```\n- [ ] a\n```\n', OPTIONS).tasks, []);
  assert.deepEqual(renderResult('- [ ] a\n', { ...OPTIONS, extensions: [] }).tasks, []);
});

describe('the preview page (headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch();
  });
  after(async () => browser?.close());

  async function open({ token = 'tok-1' } = {}) {
    const page = await browser.newPage();
    await page.goto('/preview.html');
    await page.eval(`window.OPTIONS = ${JSON.stringify(optionsJSON)}; window.wait = (ms) => new Promise((r) => setTimeout(r, ms));`);
    if (token) await page.eval(`MacDown2Preview.setTaskToken(${JSON.stringify(token)})`);
    return page;
  }
  const render = (page, md, version) => page.eval(`MacDown2Preview.update(${JSON.stringify(md)}, OPTIONS, ${version})`);
  const toggles = (page) => page.eval('__msgs.filter((m) => m.type === "toggleTask")');
  const box = (n) => `document.querySelectorAll('#doc input.task-list-item-checkbox')[${n}]`;

  test('with the app token the page enables checkboxes; without it they stay disabled and clicks do nothing', async () => {
    const early = await open({ token: null });
    try {
      await render(early, DOC, 1);
      assert.equal(await early.eval(`document.querySelectorAll('#doc input.task-list-item-checkbox:not([disabled])').length`), 0);
      await early.eval(`${box(0)}.click()`);
      assert.deepEqual(await toggles(early), []);
    } finally {
      await early.close();
    }
    const page = await open();
    try {
      await render(page, DOC, 1);
      assert.equal(await page.eval(`document.querySelectorAll('#doc input.task-list-item-checkbox').length`), 5);
      assert.equal(await page.eval(`document.querySelectorAll('#doc input.task-list-item-checkbox:not([disabled])').length`), 5);
    } finally {
      await page.close();
    }
  });

  test('a click posts the token, the item line, the wanted state and the render version, and nothing else', async () => {
    const page = await open({ token: 'secret-7' });
    try {
      await render(page, DOC, 41);
      for (const n of [0, 1, 2, 3, 4]) await page.eval(`${box(n)}.click()`);
      const tasks = renderResult(DOC, OPTIONS).tasks.map((t) => t.line);
      assert.deepEqual((await page.eval('__msgs.filter((m) => m.type === "toggleTask").map((m) => m.line)')), tasks); // the page and the renderer agree on every line
      assert.deepEqual(await toggles(page), [
        { type: 'toggleTask', token: 'secret-7', line: 0, checked: true, version: 41 },
        { type: 'toggleTask', token: 'secret-7', line: 1, checked: false, version: 41 },
        { type: 'toggleTask', token: 'secret-7', line: 2, checked: true, version: 41 },
        { type: 'toggleTask', token: 'secret-7', line: 4, checked: false, version: 41 },
        { type: 'toggleTask', token: 'secret-7', line: 6, checked: true, version: 41 },
      ]);
      // the page holds the token in script memory only
      assert.equal((await page.eval('document.documentElement.outerHTML')).includes('secret-7'), false);
    } finally {
      await page.close();
    }
  });

  test('every click is one message: blocks that arrive in a patch need no listener of their own', async () => {
    const page = await open();
    try {
      await render(page, '- [ ] a\n', 1);
      await render(page, '- [ ] a\n\n- [ ] later\n', 2); // patch: the second list is a new block
      await page.eval(`${box(1)}.click()`);
      await page.eval(`${box(0)}.click()`);
      const sent = await toggles(page);
      assert.deepEqual(sent.map((m) => [m.line, m.version]), [[2, 2], [0, 2]]);
    } finally {
      await page.close();
    }
  });

  test('lines follow the source when text is added above (the patcher shifts kept blocks)', async () => {
    const page = await open();
    try {
      await render(page, '# T\n\n- [ ] a\n', 1);
      await render(page, '# T\n\nnew para\n\nand another\n\n- [ ] a\n', 2);
      await page.eval(`${box(0)}.click()`);
      assert.deepEqual((await toggles(page)).map((m) => m.line), [6]);
    } finally {
      await page.close();
    }
  });

  test('the version a click carries is the one of the last render the page finished', async () => {
    const page = await open();
    try {
      await render(page, '- [ ] a\n', 5);
      await page.eval(`${box(0)}.click()`);
      await render(page, '- [ ] a\n\nmore\n', 6);
      await page.eval(`${box(0)}.click()`);
      assert.deepEqual((await toggles(page)).map((m) => m.version), [5, 6]);
    } finally {
      await page.close();
    }
  });

  test('the keyboard works: Space on a focused checkbox is a toggle, and focus survives the re-render it causes', async () => {
    const page = await open();
    try {
      await render(page, '- [ ] a\n- [ ] b\n', 1);
      await page.eval(`${box(1)}.focus()`);
      for (const type of ['keyDown', 'keyUp']) await page.send('Input.dispatchKeyEvent', { type, key: ' ', code: 'Space', text: ' ', windowsVirtualKeyCode: 32 });
      assert.deepEqual((await toggles(page)).map((m) => [m.line, m.checked]), [[1, true]]);
      // the app edits the source and renders again: the block's nodes are replaced, the focus goes back to the same item
      await render(page, '- [ ] a\n- [x] b\n', 2);
      assert.equal(await page.eval(`document.activeElement === ${box(1)} && ${box(1)}.checked`), true);
    } finally {
      await page.close();
    }
  });

  test('a refused toggle is taken back: resyncTasks restores what the source says', async () => {
    const page = await open();
    try {
      await render(page, '- [ ] a\n- [x] b\n', 1);
      await page.eval(`${box(0)}.click(); ${box(1)}.click()`);
      assert.deepEqual(await page.eval(`[${box(0)}.checked, ${box(1)}.checked]`), [true, false]); // optimistic
      await page.eval('MacDown2Preview.resyncTasks()');
      assert.deepEqual(await page.eval(`[${box(0)}.checked, ${box(1)}.checked]`), [false, true]);
    } finally {
      await page.close();
    }
  });

  test('the new state arrives through the normal patch: unchanged blocks keep their nodes, only the list is replaced', async () => {
    const page = await open();
    try {
      await render(page, '# Title\n\n- [ ] a\n\nlast paragraph\n', 1);
      await page.eval(`window.h = document.querySelector('#doc h1'); window.p = document.querySelector('#doc > p:last-of-type'); window.ul = document.querySelector('#doc ul')`);
      const meta = JSON.parse(await render(page, '# Title\n\n- [x] a\n\nlast paragraph\n', 2));
      assert.equal(meta.perf.mode, 'patch');
      assert.equal(meta.perf.created, 1);
      assert.equal(await page.eval(`h === document.querySelector('#doc h1') && p === document.querySelector('#doc > p:last-of-type') && ul !== document.querySelector('#doc ul')`), true);
      assert.equal(await page.eval(`${box(0)}.checked && !${box(0)}.disabled`), true);
      assert.equal(page.navigations, 1); // never a reload
    } finally {
      await page.close();
    }
  });

  test('only checkboxes of the renderer stay enabled: raw HTML without a source line, or inside an included file, does not', async () => {
    const page = await open();
    try {
      const md = [
        '<div><input type="checkbox" class="task-list-item-checkbox" disabled> raw, no data-line</div>',
        '',
        '<div data-include="part.qmd"><ul><li data-line="3"><input type="checkbox" class="task-list-item-checkbox" disabled> included</li></ul></div>',
        '',
        '- [ ] real',
        '',
      ].join('\n');
      await render(page, md, 1);
      assert.deepEqual(await page.eval(`[...document.querySelectorAll('#doc input.task-list-item-checkbox')].map((b) => b.disabled)`), [true, true, false]);
      await page.eval(`document.querySelectorAll('#doc input.task-list-item-checkbox')[0].click(); document.querySelectorAll('#doc input.task-list-item-checkbox')[1].click()`);
      assert.deepEqual(await toggles(page), []);
    } finally {
      await page.close();
    }
  });

  test('a render that fails keeps the version of the content still on the page', async () => {
    const page = await open();
    try {
      await render(page, '- [ ] a\n', 3);
      await page.eval(`MacDown2Preview.update('- [ ] a\\n', '{"flavor":"no-such-flavor"}', 4)`); // throws inside: error bar, old content stays
      await page.eval(`${box(0)}.click()`);
      assert.deepEqual((await toggles(page)).map((m) => m.version), [3]);
    } finally {
      await page.close();
    }
  });
});
