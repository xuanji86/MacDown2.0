// Headless Chrome for the preview page tests: the real preview.html + render.bundle.js + preview.bundle.js (built here
// from source, so a test never runs against stale generated files) served from a loopback HTTP server, driven over the
// DevTools protocol. WebKit is not available outside the app, so this checks everything that does not depend on the
// engine (DOM patching, line <-> y mapping, scroll reports, CSP, navigation counts); what only WKWebView can decide
// (the navigation policy itself) is covered by Swift tests.
//
// Chrome is optional: without one the tests that need it are skipped (`chromeAvailable`), set CHROME_BIN to point at a
// binary. Every run gets its own --user-data-dir, so it never touches the user's browser profile.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { build } from 'esbuild';

const web = join(dirname(fileURLToPath(import.meta.url)), '../..');

function findChrome() {
  const candidates = [
    process.env.CHROME_BIN,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  return candidates.find((p) => p && existsSync(p)) ?? null;
}
export const chromePath = findChrome();
export const chromeAvailable = chromePath !== null;

const NONCE = 'test-nonce';
let assets; // the built page, once per process

function buildAssets() {
  if (assets) return assets;
  assets = (async () => {
    const dir = mkdtempSync(join(tmpdir(), 'md2-preview-assets-'));
    const common = { bundle: true, format: 'iife', target: 'es2022', logLevel: 'warning', tsconfigRaw: '{}' };
    await build({ ...common, entryPoints: [join(web, 'src/render/index.ts')], outfile: join(dir, 'render.bundle.js'), globalName: 'MacDown2' });
    await build({ ...common, entryPoints: [join(web, 'src/preview/main.ts')], outfile: join(dir, 'preview.bundle.js'), globalName: 'MacDown2Preview' });
    mkdirSync(join(dir, 'preview-styles'));
    mkdirSync(join(dir, 'katex'));
    mkdirSync(join(dir, 'hljs-themes'));
    const styles = join(web, 'src/preview/preview-styles');
    writeFileSync(join(dir, 'preview-styles/github.css'), `${readFileSync(join(styles, '_base.css'), 'utf8')}\n${readFileSync(join(styles, 'github.css'), 'utf8')}`);
    writeFileSync(join(dir, 'katex/katex.min.css'), readFileSync(join(web, 'node_modules/katex/dist/katex.min.css'), 'utf8').replace(/url\([^)]+\)/g, 'url()'));
    writeFileSync(join(dir, 'hljs-themes/github.css'), readFileSync(join(web, 'node_modules/highlight.js/styles/github.css'), 'utf8'));
    return { dir, previewHTML: readFileSync(join(web, 'src/preview/preview.html'), 'utf8') };
  })();
  return assets;
}

// Minimal DevTools protocol client over the browser websocket (flat sessions).
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = [];
    ws.addEventListener('message', (e) => {
      const m = JSON.parse(e.data);
      if (m.id) {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) p?.reject(new Error(`${p.method}: ${m.error.message}`));
        else p?.resolve(m.result);
      } else for (const l of this.listeners) l(m);
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
  on(fn) {
    this.listeners.push(fn);
  }
}

// routes: { '/path': (req, res) => void } for test-specific endpoints (slow images, request counters).
// Returns { newPage, hits, close }; `hits` counts requests per pathname.
export async function launch({ routes = {} } = {}) {
  if (!chromePath) throw new Error('no Chrome found (set CHROME_BIN)');
  const { dir, previewHTML } = await buildAssets();
  const hits = {};
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    hits[url.pathname] = (hits[url.pathname] ?? 0) + 1;
    if (routes[url.pathname]) return routes[url.pathname](req, res, url);
    if (url.pathname === '/preview.html') {
      let html = previewHTML.replaceAll('__CSP_NONCE__', NONCE);
      // The app serves everything from macdown2-res://app; here that origin is the loopback server ('self').
      html = html.replaceAll('macdown2-res://app', "'self'").replace('img-src macdown2-res:', "img-src 'self' macdown2-res:");
      if (url.searchParams.get('csp') === '0') html = html.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '');
      res.setHeader('Content-Type', 'text/html');
      return res.end(html);
    }
    // Any other style / highlight theme the page asks for gets the github one: the tests are about the page, not the palette.
    const pathname = url.pathname.replace(/^\/(preview-styles|hljs-themes)\/[^/]+\.css$/, '/$1/github.css');
    const file = join(dir, pathname);
    if (!file.startsWith(dir) || !existsSync(file)) {
      res.statusCode = 404;
      return res.end('not found');
    }
    res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'application/octet-stream');
    res.end(readFileSync(file));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${server.address().port}`;

  const profile = mkdtempSync(join(tmpdir(), 'md2-chrome-profile-'));
  const proc = spawn(
    chromePath,
    ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--disable-extensions', '--disable-background-networking', 'about:blank'],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  const wsUrl = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('Chrome did not start')), 20000);
    proc.stderr.on('data', (d) => {
      buf += d;
      const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    proc.on('exit', () => reject(new Error('Chrome exited early')));
  });
  const ws = new WebSocket(wsUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  const cdp = new CDP(ws);

  async function newPage({ width = 900, height = 700 } = {}) {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const send = (method, params) => cdp.send(method, params, sessionId);
    let navigations = 0;
    cdp.on((m) => {
      if (m.sessionId !== sessionId) return;
      if (m.method === 'Page.frameNavigated' && !m.params.frame.parentId) navigations++;
      if (m.method === 'Page.navigatedWithinDocument') navigations++;
    });
    await send('Page.enable');
    await send('Runtime.enable');
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    // What preview.html's bridge talks to inside WKWebView.
    await send('Page.addScriptToEvaluateOnNewDocument', {
      source: 'window.__msgs = []; window.webkit = { messageHandlers: { macdown2: { postMessage: (m) => window.__msgs.push(m) } } };',
    });
    const page = {
      origin,
      get navigations() {
        return navigations;
      },
      async goto(path) {
        const loaded = new Promise((resolve) => cdp.on((m) => m.sessionId === sessionId && m.method === 'Page.loadEventFired' && resolve()));
        await send('Page.navigate', { url: origin + path });
        await loaded;
      },
      // Runs `expr` (an expression or an async IIFE) in the page and returns its JSON-able value.
      async eval(expr) {
        const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
        if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
        return r.result.value;
      },
      async close() {
        await cdp.send('Target.closeTarget', { targetId }).catch(() => {});
      },
    };
    return page;
  }

  return {
    origin,
    hits,
    newPage,
    async close() {
      try {
        ws.close();
      } catch {}
      proc.kill('SIGKILL');
      await new Promise((r) => (proc.exitCode === null ? proc.once('exit', r) : r()));
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
      rmSync(profile, { recursive: true, force: true });
    },
  };
}

// A solid-colour PNG of the given size (so a slow image can have a known height).
export function png(width, height, [r, g, b] = [200, 120, 40]) {
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: width }, () => [r, g, b]).flat())]);
  const raw = Buffer.concat(Array.from({ length: height }, () => row));
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const head = Buffer.alloc(13);
  head.writeUInt32BE(width, 0);
  head.writeUInt32BE(height, 4);
  head[8] = 8; // bit depth
  head[9] = 2; // RGB
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', head), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
