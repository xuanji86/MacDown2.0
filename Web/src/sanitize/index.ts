// sanitize.chunk.js: the HTML sanitizer (parse5 + allowlist, sanitize.ts) for output that leaves the app. Loaded after
// render.bundle.js, only for a render with `sanitize: true` (JSCRenderer adds it); it registers itself with the main bundle and
// nothing else. The preview page never loads it: it has its own stripping and CSP. The main bundle fails closed without it.
import { sanitizeHtml } from './sanitize.ts';

declare const MacDown2: { sanitizer: { register(fn: (html: string) => string): void } };

MacDown2.sanitizer.register(sanitizeHtml);
