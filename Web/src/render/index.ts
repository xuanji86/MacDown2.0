// Renderer entry point. Bundled as an IIFE exposing `globalThis.MacDown2`; the same bundle runs in the preview WebView and
// in JavaScriptCore (Quick Look, CLI, export, tests). Whole-document rendering is core.ts, the preview's incremental
// renderer incremental.ts, the preview's per-block inline source map inline-map.ts; this file names what the global offers.
export { flavors, render, renderResult, sanitizer } from './core.ts';
export type { BlockMap, OutlineItem, RenderOptions, RenderResult, TaskItem } from './core.ts';
export { incremental, renderIncremental } from './incremental.ts';
export { inlineMap } from './inline-map.ts';
