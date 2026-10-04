// Loads a script chunk (flavor chunks, the mermaid chunk) once per page, with the page's CSP nonce.
const loadedChunks = new Map<string, Promise<void>>();

export function loadChunk(src: string): Promise<void> {
  let loading = loadedChunks.get(src);
  if (!loading) {
    loading = new Promise<void>((resolve, reject) => {
      const el = document.createElement('script');
      el.nonce = (document.querySelector('script[nonce]') as HTMLScriptElement | null)?.nonce ?? '';
      el.src = src;
      el.onload = () => resolve();
      el.onerror = () => {
        loadedChunks.delete(src); // let the next update try again
        reject(new Error(`could not load ${src}`));
      };
      document.head.append(el);
    });
    loadedChunks.set(src, loading);
  }
  return loading;
}
