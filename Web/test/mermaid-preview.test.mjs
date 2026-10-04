// Mermaid in the real preview page, in headless Chrome (WebKit is not scriptable from here, but the page logic and the
// CSP are the same): lazy chunk load, SVG output, block-level redraw, errors, dark theme. Skipped when there is no Chrome.
//
// The page is the committed preview.html with its CSP kept as is (script-src nonce + origin, no unsafe-eval), served over
// http with `macdown2-res://app` replaced by 'self', plus one extra nonce'd script that drives MacDown2Preview.update().
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const res = join(here, '../../Packages/WebAssets/Sources/WebAssets/Resources');
const chrome = [process.env.CHROME, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'].find((p) => p && existsSync(p));

const options = {
  flavor: 'markdown',
  extensions: ['tables', 'strikethrough', 'autolink', 'math', 'frontMatter'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'table',
};

// Runs in the page. Reports everything the assertions need as one JSON string in <body data-result>.
const driver = `(async () => {
  if (document.readyState === 'loading') await new Promise((r) => addEventListener('DOMContentLoaded', r));
  const out = { steps: {}, violations: [] };
  document.addEventListener('securitypolicyviolation', (e) => out.violations.push(e.violatedDirective + ' ' + e.blockedURI));
  addEventListener('unhandledrejection', (e) => out.violations.push('rejection ' + e.reason));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (cond) => { for (let i = 0; i < 600 && !cond(); i++) await sleep(50); if (!cond()) throw new Error('timeout'); };
  const pres = () => [...document.querySelectorAll('pre.mermaid-source')];
  const settled = (n) => () => pres().length === n && pres().every((p) => p.dataset.mermaid);
  const chunkLoaded = () => !!document.querySelector('script[src="mermaid.chunk.js"]');
  const OPTIONS = ${JSON.stringify(options)};
  const update = (md) => JSON.parse(MacDown2Preview.update(md, JSON.stringify(OPTIONS)));
  const flow = (a, b) => '\`\`\`mermaid\\ngraph TD\\n  ' + a + ' --> ' + b + '\\n\`\`\`\\n';
  const seq = '\`\`\`mermaid\\nsequenceDiagram\\n  Alice->>Bob: hi\\n\`\`\`\\n';
  try {
    // 1. no diagram: the chunk is never requested
    update('# Hello\\n\\n\`\`\`js\\nlet a = 1;\\n\`\`\`\\n');
    await sleep(300);
    out.steps.lazy = { chunkLoaded: chunkLoaded(), sourceBlocks: pres().length };

    // 2. two diagrams
    update('# Doc\\n\\npara\\n\\n' + flow('A', 'B') + '\\n' + seq);
    await until(settled(2));
    const [d1, d2] = pres();
    const svg1 = d1.querySelector('svg'), svg2 = d2.querySelector('svg');
    out.steps.draw = {
      chunkLoaded: chunkLoaded(), states: pres().map((p) => p.dataset.mermaid + '/' + p.dataset.mermaidTheme),
      svgs: pres().map((p) => p.querySelectorAll('svg').length), codeHidden: getComputedStyle(d1.querySelector('code')).display,
      text1: d1.textContent.includes('A') && d1.textContent.includes('B'), dataLine: d1.getAttribute('data-line'),
    };

    // 3. edit the paragraph: nothing is redrawn; edit the second diagram: only that one is
    update('# Doc\\n\\nparagraph changed\\n\\n' + flow('A', 'B') + '\\n' + seq);
    await sleep(300);
    out.steps.patchPara = { sameNode1: pres()[0] === d1, sameSvg1: d1.querySelector('svg') === svg1, sameNode2: pres()[1] === d2, sameSvg2: d2.querySelector('svg') === svg2 };
    update('# Doc\\n\\nparagraph changed\\n\\n' + flow('A', 'B') + '\\n' + seq.replace('hi', 'hello'));
    await until(() => pres()[1] && pres()[1].dataset.mermaid && pres()[1].textContent.includes('hello'));
    out.steps.patchDiagram = { sameNode1: pres()[0] === d1, sameSvg1: d1.querySelector('svg') === svg1, newNode2: pres()[1] !== d2, svg2: pres()[1].querySelectorAll('svg').length };

    // 4. a diagram with a syntax error keeps its source and shows the message; the page is still alive
    update('# Doc\\n\\n' + flow('A', 'B') + '\\n\`\`\`mermaid\\nthis is not a diagram\\n\`\`\`\\n');
    await until(settled(2));
    const bad = pres()[1];
    out.steps.error = { state: bad.dataset.mermaid, svgs: bad.querySelectorAll('svg').length, message: (bad.querySelector('.mermaid-error') || {}).textContent, codeShown: getComputedStyle(bad.querySelector('code')).display !== 'none', strayNodes: document.querySelectorAll('body > [id*="md2-mermaid"]').length };

    // 5. dark style: every diagram is redrawn with the dark theme
    MacDown2Preview.setStyle('github-dark', null);
    await until(() => pres().every((p) => p.dataset.mermaidTheme === 'dark'));
    out.steps.dark = { themes: pres().map((p) => p.dataset.mermaidTheme), okSvg: pres()[0].querySelectorAll('svg').length, colorScheme: getComputedStyle(document.documentElement).colorScheme };
    MacDown2Preview.setStyle('github', null);
    await until(() => pres().every((p) => p.dataset.mermaidTheme === 'default'));
    out.steps.light = { themes: pres().map((p) => p.dataset.mermaidTheme) };
  } catch (e) {
    out.failure = String(e && e.stack || e);
  }
  document.body.dataset.result = encodeURIComponent(JSON.stringify(out));
})();`;

async function runPage() {
  const nonce = 'testnonce';
  const server = createServer((req, resp) => {
    const path = new URL(req.url, 'http://x').pathname;
    if (path === '/') {
      const html = readFileSync(join(res, 'preview.html'), 'utf8')
        .replaceAll('macdown2-res://app', "'self'")
        .replaceAll('__CSP_NONCE__', nonce)
        .replace('</head>', `<script nonce="${nonce}" src="driver.js"></script>\n</head>`);
      resp.writeHead(200, { 'content-type': 'text/html' }).end(html);
    } else if (path === '/driver.js') {
      resp.writeHead(200, { 'content-type': 'text/javascript' }).end(driver);
    } else {
      const file = normalize(join(res, path));
      if (!file.startsWith(res) || !existsSync(file)) return void resp.writeHead(404).end();
      const type = { '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' }[extname(file)] ?? 'application/octet-stream';
      resp.writeHead(200, { 'content-type': type }).end(readFileSync(file));
    }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const profile = mkdtempSync(join(tmpdir(), 'md2-chrome-')); // never share a profile with the user's own Chrome
  try {
    // Chrome prints the DOM and then lingers (GPU/updater helpers), so the dump itself is the signal to stop it.
    const dom = await new Promise((resolve, reject) => {
      const child = spawn(
        chrome,
        ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', ...(process.env.MD2_CHROME_LOG ? ['--enable-logging=stderr', '--v=0'] : []), `--user-data-dir=${profile}`, '--virtual-time-budget=120000', '--dump-dom', `http://127.0.0.1:${server.address().port}/`],
        { stdio: ['ignore', 'pipe', process.env.MD2_CHROME_LOG ? openSync(process.env.MD2_CHROME_LOG, 'w') : 'ignore'] },
      );
      let out = '';
      const timer = setTimeout(() => (child.kill('SIGKILL'), reject(new Error('Chrome did not dump the page in time'))), 150000);
      child.stdout.on('data', (d) => {
        out += d;
        if (out.includes('</html>')) child.kill('SIGTERM');
      });
      child.on('error', reject);
      child.on('close', () => (clearTimeout(timer), resolve(out))); // wait for it to go, so the profile directory is free to delete
    });
    if (process.env.MD2_DUMP_DOM) writeFileSync(process.env.MD2_DUMP_DOM, dom); // debugging aid
    const m = dom.match(/data-result="([^"]*)"/);
    assert.ok(m, 'the page never reported (driver did not finish)');
    return JSON.parse(decodeURIComponent(m[1]));
  } finally {
    server.close();
    rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
}

test('preview page draws mermaid blocks lazily, redraws only changed ones, reports errors, follows dark styles', { skip: !chrome && 'no Chrome found (set CHROME=…)', timeout: 180000 }, async () => {
  const r = await runPage();
  assert.equal(r.failure, undefined, r.failure);
  assert.deepEqual(r.violations, [], 'CSP violations or unhandled rejections');
  const { steps: s } = r;
  assert.deepEqual(s.lazy, { chunkLoaded: false, sourceBlocks: 0 }, 'no diagram, no chunk');
  assert.equal(s.draw.chunkLoaded, true);
  assert.deepEqual(s.draw.states, ['ok/default', 'ok/default']);
  assert.deepEqual(s.draw.svgs, [1, 1]);
  assert.equal(s.draw.codeHidden, 'none');
  assert.equal(s.draw.text1, true);
  assert.ok(Number(s.draw.dataLine) >= 0);
  assert.deepEqual(s.patchPara, { sameNode1: true, sameSvg1: true, sameNode2: true, sameSvg2: true });
  assert.deepEqual(s.patchDiagram, { sameNode1: true, sameSvg1: true, newNode2: true, svg2: 1 });
  assert.equal(s.error.state, 'error');
  assert.equal(s.error.svgs, 0);
  assert.match(s.error.message, /^Mermaid: /);
  assert.equal(s.error.codeShown, true);
  assert.equal(s.error.strayNodes, 0, 'a failed render must not leave mermaid scratch nodes in <body>');
  assert.deepEqual(s.dark.themes, ['dark', 'dark']);
  assert.equal(s.dark.okSvg, 1);
  assert.equal(s.dark.colorScheme, 'dark');
  assert.deepEqual(s.light.themes, ['default', 'default']);
});
