// markdown-it-emoji ships no type declarations.
declare module 'markdown-it-emoji/lib/full.mjs' {
  import type { PluginWithOptions } from 'markdown-it';
  const plugin: PluginWithOptions<{ defs?: Record<string, string>; shortcuts?: Record<string, string | string[]>; enabled?: string[] }>;
  export default plugin;
}
