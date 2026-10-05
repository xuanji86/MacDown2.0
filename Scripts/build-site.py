#!/usr/bin/env python3
"""Builds the landing page in docs/ from its single source, Scripts/site/index.src.html (run by `make site`; `--check` by `make test`).

The source holds both languages, each text as `<span class="en">…</span><span class="zh">…</span>`. This script writes
  docs/index.html      English, served at /MacDown2.0/
  docs/zh/index.html   Simplified Chinese, served at /MacDown2.0/zh/
  docs/sitemap.xml     both URLs with hreflang alternates
Each page keeps only its own language (no hidden text of the other one), and carries its own <title>, description, canonical,
hreflang, Open Graph / Twitter tags and JSON-LD. The version shown on the page and in the JSON-LD is the newest
docs/release-notes/<version>.md. Edit the source, never the generated files; bump LASTMOD when the page content changes.
"""
import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
SRC = ROOT / "Scripts/site/index.src.html"
SITE = "https://xuanji86.github.io/MacDown2.0/"
REPO = "https://github.com/xuanji86/MacDown2.0"
DMG = REPO + "/releases/latest/download/MacDown2.dmg"
LASTMOD = "2026-10-05"
OG_SIZE = (2400, 1800)

LANGS = {
    "en": {
        "html_lang": "en",
        "path": "",  # relative to SITE
        "prefix": "",  # from the page back to docs/
        "hreflang": "en",
        "locale": "en_US",
        "other_locale": "zh_CN",
        "title": "MacDown2.0 — Free Markdown editor for Apple Silicon Macs, the new MacDown",
        "description": "A new MacDown for Apple Silicon: free, open-source Markdown editor for Mac (M1–M5 and Intel), native on macOS 26, with live preview, GitHub Markdown, math and Mermaid. The spiritual successor to MacDown, rebuilt in Swift.",
        "og_description": "A new MacDown, rebuilt natively for Apple Silicon and macOS 26: a free, open-source Markdown editor with a live preview that re-renders only what you changed.",
        "image": "images/screenshot.png",
        "image_alt": "MacDown2.0 editing a Markdown document: dark source editor on the left, live preview on the right",
    },
    "zh": {
        "html_lang": "zh-CN",
        "path": "zh/",
        "prefix": "../",
        "hreflang": "zh-CN",
        "locale": "zh_CN",
        "other_locale": "en_US",
        "title": "MacDown2.0 — MacDown 新版，支持苹果芯片的免费 Mac Markdown 编辑器",
        "description": "MacDown 新版精神续作，原生支持苹果芯片（M1–M5）与 Intel：免费开源的 Mac Markdown 编辑器，macOS 26 原生应用，实时预览，支持 GitHub 风格 Markdown、公式与 Mermaid，用 Swift 从零重写。",
        "og_description": "MacDown 的新一代精神续作，为苹果芯片和 macOS 26 原生重写的免费开源 Markdown 编辑器，实时预览只重新渲染改动过的部分。",
        "image": "images/screenshot.zh-CN.png",
        "image_alt": "MacDown2.0 正在编辑一份 Markdown 文档：左边是深色编辑区里的源码，右边是实时预览",
    },
}

# A returning visitor who explicitly picked 中文 is sent from / to /zh/. Not on back/forward (that would trap the back
# button), not for /zh/ (a Chinese search result must stay Chinese), and never from the browser's language: crawlers see
# each URL as it is.
REDIRECT = ('try{if(localStorage.getItem("macdown2-lang")==="zh"){var n=performance.getEntriesByType("navigation")[0];'
            'if(n&&n.type==="navigate")location.replace("zh/"+location.search+location.hash)}}catch(e){}')


# Attribute text (not wrappable in language spans) that the zh page translates.
ZH_ATTRS = {'aria-label="Sections"': 'aria-label="页面章节"', 'alt="MacDown2.0 app icon"': 'alt="MacDown2.0 应用图标"'}


def version() -> str:
    notes = [p.stem for p in (DOCS / "release-notes").glob("*.md")]
    return max(notes, key=lambda v: tuple(int(x) for x in v.split(".")))


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")


def json_ld(lang: str, ver: str) -> dict:
    c = LANGS[lang]
    return {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "MacDown2.0",
        "alternateName": ["MacDown 2.0", "MacDown2"],
        "description": c["description"],
        "url": SITE + c["path"],
        "inLanguage": c["html_lang"],
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "macOS 26",
        "softwareVersion": ver,
        "releaseNotes": f"{REPO}/releases/tag/v{ver}",
        "downloadUrl": DMG,
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "image": SITE + "images/icon.png",
        "screenshot": SITE + c["image"],
        "author": {"@type": "Person", "name": "xuanji86", "url": "https://github.com/xuanji86"},
        "sameAs": [REPO],
    }


def head(lang: str, ver: str) -> str:
    c = LANGS[lang]
    url = SITE + c["path"]
    img = SITE + c["image"]
    p = c["prefix"]
    t, d, od = esc(c["title"]), esc(c["description"]), esc(c["og_description"])
    alt = esc(c["image_alt"])
    lines = [
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>{t}</title>",
        f'<meta name="description" content="{d}">',
        '<meta name="robots" content="index, follow, max-image-preview:large">',
        '<meta name="color-scheme" content="light dark">',
        '<meta name="theme-color" content="#fbfbfa" media="(prefers-color-scheme: light)">',
        '<meta name="theme-color" content="#0e0f11" media="(prefers-color-scheme: dark)">',
        f'<link rel="canonical" href="{url}">',
        f'<link rel="alternate" hreflang="en" href="{SITE}">',
        f'<link rel="alternate" hreflang="zh-CN" href="{SITE}zh/">',
        f'<link rel="alternate" hreflang="x-default" href="{SITE}">',
        f'<link rel="icon" type="image/png" href="{p}images/icon.png">',
        f'<link rel="apple-touch-icon" href="{p}images/icon.png">',
        "",
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="MacDown2.0">',
        f'<meta property="og:title" content="{t}">',
        f'<meta property="og:description" content="{od}">',
        f'<meta property="og:url" content="{url}">',
        f'<meta property="og:image" content="{img}">',
        '<meta property="og:image:type" content="image/png">',
        f'<meta property="og:image:width" content="{OG_SIZE[0]}">',
        f'<meta property="og:image:height" content="{OG_SIZE[1]}">',
        f'<meta property="og:image:alt" content="{alt}">',
        f'<meta property="og:locale" content="{c["locale"]}">',
        f'<meta property="og:locale:alternate" content="{c["other_locale"]}">',
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:title" content="{t}">',
        f'<meta name="twitter:description" content="{od}">',
        f'<meta name="twitter:image" content="{img}">',
        f'<meta name="twitter:image:alt" content="{alt}">',
        "",
        '<link rel="preconnect" href="https://fonts.googleapis.com">',
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>',
        '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&amp;family=Geist+Mono:wght@400;500&amp;display=swap">',
        f'<link rel="stylesheet" href="{p}site.css">',
    ]
    if lang == "en":
        lines.append(f"<script>{REDIRECT}</script>")
    lines.append(f'<script src="{p}site.js" defer></script>')
    lines.append('<script type="application/ld+json">')
    lines.append(json.dumps(json_ld(lang, ver), indent=2, ensure_ascii=False))
    lines.append("</script>")
    return "\n".join(lines)


def toggle(lang: str) -> str:
    en_href, zh_href = ("./", "zh/") if lang == "en" else ("../", "./")
    cur_en = ' aria-current="page"' if lang == "en" else ""
    cur_zh = ' aria-current="page"' if lang == "zh" else ""
    return (
        '<div class="seg" role="group" aria-label="Language / 语言">\n'
        f'        <a href="{en_href}" hreflang="en" lang="en" data-lang="en"{cur_en}>EN</a>\n'
        f'        <a href="{zh_href}" hreflang="zh-CN" lang="zh-Hans" data-lang="zh"{cur_zh}>中文</a>\n'
        "      </div>"
    )


VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Pick(HTMLParser):
    """Copies the source, keeping elements marked for `keep` (their marker class removed; a bare <span> is unwrapped) and
    dropping those marked for the other language."""

    def __init__(self, keep: str):
        super().__init__(convert_charrefs=False)
        self.keep, self.drop = keep, ("zh" if keep == "en" else "en")
        self.out: list[str] = []
        self.stack: list[tuple[str, str]] = []
        self.dropping = 0

    def start(self, tag, attrs, raw, selfclosing):
        void = tag in VOID or selfclosing
        if self.dropping:
            if not void:
                self.stack.append((tag, "in"))
            return
        classes = (dict(attrs).get("class") or "").split()
        if self.drop in classes:
            if not void:
                self.stack.append((tag, "drop"))
                self.dropping += 1
            return
        if self.keep in classes:
            rest = [c for c in classes if c != self.keep]
            if not rest and tag == "span":
                if not void:
                    self.stack.append((tag, "unwrap"))
                return
            raw = re.sub(r'\s+class="[^"]*"', f' class="{" ".join(rest)}"' if rest else "", raw, count=1)
        self.out.append(raw)
        if not void:
            self.stack.append((tag, "keep"))

    def handle_starttag(self, tag, attrs):
        self.start(tag, attrs, self.get_starttag_text(), False)

    def handle_startendtag(self, tag, attrs):
        self.start(tag, attrs, self.get_starttag_text(), True)

    def handle_endtag(self, tag):
        t, action = self.stack.pop()
        assert t == tag, f"unbalanced HTML in the source: </{tag}> closes <{t}>"
        if action == "drop":
            self.dropping -= 1
        elif action == "keep":
            self.out.append(f"</{tag}>")

    def emit(self, s):
        if not self.dropping:
            self.out.append(s)

    def handle_data(self, data): self.emit(data)
    def handle_entityref(self, name): self.emit(f"&{name};")
    def handle_charref(self, name): self.emit(f"&#{name};")
    def handle_comment(self, data): self.emit(f"<!--{data}-->")
    def handle_decl(self, decl): self.emit(f"<!{decl}>")


def page(lang: str, ver: str) -> str:
    c = LANGS[lang]
    p = Pick(lang)
    p.feed(SRC.read_text(encoding="utf-8"))
    p.close()
    assert not p.stack, f"unclosed elements in the source: {p.stack}"
    s = re.sub(r"\n[ \t]+\n", "\n", "".join(p.out))  # lines left blank by the dropped language
    for en, zh in ZH_ATTRS.items():
        if lang == "zh":
            s = s.replace(en, zh)
    if c["prefix"]:
        s = re.sub(r'(?<=["\s,])(images/|site\.(?:css|js))', c["prefix"] + r"\1", s)
    for key, val in (("<!--@HEAD-->", head(lang, ver)), ("<!--@LANGTOGGLE-->", toggle(lang)), ("@LANG@", c["html_lang"]), ("@VERSION@", ver)):
        assert key in s, f"{key} missing from the source"
        s = s.replace(key, val)
    return s


def sitemap() -> str:
    alts = "".join(
        f'    <xhtml:link rel="alternate" hreflang="{h}" href="{u}"/>\n'
        for h, u in (("en", SITE), ("zh-CN", SITE + "zh/"), ("x-default", SITE))
    )
    urls = "".join(
        f"  <url>\n    <loc>{SITE + c['path']}</loc>\n    <lastmod>{LASTMOD}</lastmod>\n{alts}  </url>\n" for c in LANGS.values()
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        f"{urls}</urlset>\n"
    )


def build() -> dict[Path, str]:
    ver = version()
    return {
        DOCS / "index.html": page("en", ver),
        DOCS / "zh/index.html": page("zh", ver),
        DOCS / "sitemap.xml": sitemap(),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the generated files are stale or their JSON-LD does not parse")
    args = ap.parse_args()
    files = build()
    if not args.check:
        for path, text in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path.relative_to(ROOT)}")
        return 0
    errors = []
    for path, text in files.items():
        rel = path.relative_to(ROOT)
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            errors.append(f"{rel} is stale")
            continue
        for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, flags=re.S):
            try:
                json.loads(block)
            except ValueError as e:
                errors.append(f"{rel}: JSON-LD does not parse: {e}")
    if errors:
        print("error: " + "; ".join(errors) + ". Edit Scripts/site/index.src.html, run 'make site' and commit the result.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
