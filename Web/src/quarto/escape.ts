// HTML-escape for the places where vendored Quarto code interpolates document text into markup (see vendored/VENDORED.md).
export const escapeHtml = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
