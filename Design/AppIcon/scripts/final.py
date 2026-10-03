#!/usr/bin/env python3
"""MacDown2.0 icon, final direction C (Glass 2): composed SVGs, Icon Composer layers,
AppIcon.appiconset PNGs, Claude Design canvas + overview export."""
import os, sys, json, shutil, subprocess, time
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen  # reuses geometry / defs / CSS (rebuilds the concept icons as a side effect)

ROOT = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.dirname(ROOT)
FINAL = os.path.join(SCRATCH, "icon-final")
LAYERS = os.path.join(FINAL, "layers")
APPSET = os.path.join(FINAL, "appiconset", "AppIcon.appiconset")
SVGOUT = os.path.join(FINAL, "svg")
CANVAS = os.path.join(ROOT, "build", "final")          # Claude Design upload + export pages
ORIG = os.path.join(SCRATCH, "md3k", "MacDown", "Images.xcassets", "AppIcon.appiconset")
for d in (LAYERS, APPSET, SVGOUT, os.path.join(CANVAS, "final")):
    os.makedirs(d, exist_ok=True)

# ---------------------------------------------------------------- final parameters
LIGHT = [("0", "#5EEAEA"), ("0.45", "#1A8BDC"), ("1", "#0B3AA6")]
DARK = [("0", "#1F9FCC"), ("0.45", "#0D56A5"), ("1", "#061B54")]
ANGLE = (0, 0, 1, 1)
GLYPH_TF = "translate(58,152) scale(3.9)"          # full size: up-left, leaves room for the 2
GLYPH_TF_SMALL = "translate(60.5,243.2) scale(4.2)" # 16/32 px: centered, larger, no 2
TWO_BOX = 'x="496" y="384" width="548" height="548" viewBox="-14 -14 128 128" overflow="visible"'
TWO_W = 24
TWO_OP = {"light": "0.26", "dark": "0.26", "clear": "0.42", "tinted": "0.22"}

def wrap(defs, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{body}</svg>')

def glyph(mode, small=False, plain=False):
    tf = GLYPH_TF_SMALL if small else GLYPH_TF
    paths = f'<path d="{gen.MARK_M}"/><path d="{gen.MARK_ARROW}"/>'
    if plain:  # Icon Composer layer: flat white, no filter
        return (f'<g transform="{tf}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="5" '
                f'stroke-linejoin="round">{paths}</g>')
    if mode == "tinted":
        fill, filt, stroke, op = gen.TINT, "url(#glowt)", gen.TINT, ""
    elif mode == "clear":
        fill, filt, stroke, op = "#FFFFFF", "url(#dsn)", "#FFFFFF", ' opacity="0.96"'
    else:
        fill, filt, stroke, op = "url(#gw)", "url(#ds)", "#FFFFFF", ""
    return (f'<g filter="{filt}"{op}><g transform="{tf}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="5" stroke-linejoin="round" paint-order="stroke">{paths}</g></g>')

def two(mode, plain=False):
    if plain:
        return (f'<clipPath id="cv"><rect width="1024" height="1024"/></clipPath><g clip-path="url(#cv)">'
                f'<svg {TWO_BOX}><path d="{gen.TWO}" fill="none" stroke="#FFFFFF" stroke-width="{TWO_W}" '
                f'stroke-linecap="round" stroke-linejoin="round"/></svg></g>')
    col = gen.TINT if mode == "tinted" else "#FFFFFF"
    return (f'<g clip-path="url(#sq)"><g filter="url(#rim)"><svg {TWO_BOX}><path d="{gen.TWO}" fill="none" '
            f'stroke="{col}" stroke-opacity="{TWO_OP[mode]}" stroke-width="{TWO_W}" stroke-linecap="round" '
            f'stroke-linejoin="round"/></svg></g></g>')

def compose(mode, small=False, layers=("bg", "two", "glyph"), outline=False):
    defs = gen.DEFS_COMMON + gen.grad("bg", DARK if mode == "dark" else LIGHT, ANGLE)
    defs += gen.WP_LIGHT if mode == "clear" else gen.WP_DARK
    body = gen.wallpaper(mode) if mode in ("clear", "tinted") else ""
    if "bg" in layers:
        body += gen.bg_layer("C", mode)
    if "two" in layers and not small:
        body += two(mode)
    if "glyph" in layers:
        body += glyph(mode, small)
    if outline:
        body += gen.OUTLINE
    return wrap(defs, body)

def put(path, text):
    with open(path, "w") as f:
        f.write(text)

# composed variants (canvas + appiconset source)
FIN = os.path.join(CANVAS, "final")
V = {
    "C-light": compose("light"), "C-dark": compose("dark"),
    "C-clear": compose("clear"), "C-tinted": compose("tinted"),
    "C-small-light": compose("light", small=True), "C-small-dark": compose("dark", small=True),
    "C-l1": compose("light", layers=("bg",), outline=True),
    "C-l2": compose("light", layers=("two",), outline=True),
    "C-l3": compose("light", layers=("glyph",), outline=True),
}
for k, s in V.items():
    put(os.path.join(FIN, f"{k}.svg"), s)
for k in ("C-light", "C-dark", "C-small-light", "C-small-dark"):
    put(os.path.join(SVGOUT, f"macdown2-{k}.svg"), V[k])

# Icon Composer layers: 1024 canvas, no squircle mask, no filters, flat white foregrounds
L1 = wrap(gen.grad("bg", LIGHT, ANGLE), '<rect width="1024" height="1024" fill="url(#bg)"/>')
L1D = wrap(gen.grad("bg", DARK, ANGLE), '<rect width="1024" height="1024" fill="url(#bg)"/>')
L2 = wrap("", two("light", plain=True))
L3 = wrap("", glyph("light", plain=True))
put(os.path.join(LAYERS, "01-background.svg"), L1)
put(os.path.join(LAYERS, "01-background-dark.svg"), L1D)
put(os.path.join(LAYERS, "02-glass-2.svg"), L2)
put(os.path.join(LAYERS, "03-glyph.svg"), L3)

# original small sizes for the side-by-side
for s in (16, 32, 128):
    shutil.copy(os.path.join(ORIG, f"icon_{s}x{s}.png"), os.path.join(FIN, f"orig-{s}.png"))

# ---------------------------------------------------------------- headless chrome
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

def shot(html, out, w, h, dpr=1, transparent=False, timeout=90):
    if os.path.exists(out):
        os.remove(out)
    prof = os.path.join(SCRATCH, f"chrome-profile-{os.getpid()}-{int(time.time() * 1000)}")
    args = [CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            f"--user-data-dir={prof}", "--hide-scrollbars", f"--force-device-scale-factor={dpr}",
            f"--window-size={w},{h}", f"--screenshot={out}", f"file://{html}"]
    if transparent:
        args.insert(1, "--default-background-color=00000000")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(timeout * 2):
        time.sleep(0.5)
        if os.path.exists(out) and os.path.getsize(out) > 0:
            time.sleep(0.8)
            break
    p.kill()
    shutil.rmtree(prof, ignore_errors=True)
    assert os.path.exists(out) and os.path.getsize(out) > 0, f"render failed: {out}"

# ---------------------------------------------------------------- appiconset PNGs (one sprite render, then crop)
SIZES = [1024, 512, 256, 128, 64, 32, 16]
sprite, y = [], 0
pos = {}
for s in SIZES:
    src = "C-small-light.svg" if s <= 32 else "C-light.svg"
    sh = f"drop-shadow(0 {s * 0.01:.2f}px {s * 0.012:.2f}px rgba(0,0,0,0.30))"
    sprite.append(f'<img src="final/{src}" width="{s}" height="{s}" style="position:absolute;left:0;top:{y}px;filter:{sh}">')
    pos[s] = y
    y += s
put(os.path.join(CANVAS, "_sprite.html"),
    '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent}img{display:block}</style></head><body>'
    + "".join(sprite) + "</body></html>")
shot(os.path.join(CANVAS, "_sprite.html"), os.path.join(CANVAS, "_sprite.png"), 1024, y, transparent=True)
sp = Image.open(os.path.join(CANVAS, "_sprite.png")).convert("RGBA")
tiles = {s: sp.crop((0, pos[s], s, pos[s] + s)) for s in SIZES}
NAMES = [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
         ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
         ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]
for name, s in NAMES:
    tiles[s].save(os.path.join(APPSET, name), "PNG", optimize=True)
contents = {"images": [], "info": {"author": "xcode", "version": 1}}
for name, s in NAMES:
    pt = int(name.split("_")[1].split("x")[0])
    contents["images"].append({"filename": name, "idiom": "mac", "scale": "2x" if "@2x" in name else "1x", "size": f"{pt}x{pt}"})
with open(os.path.join(APPSET, "Contents.json"), "w") as f:
    json.dump(contents, f, indent=2)
    f.write("\n")

# layer PNGs (1024, alpha) in one render
put(os.path.join(CANVAS, "_layers.html"),
    '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent}img{display:block;position:absolute;left:0}</style></head><body>'
    '<img src="../../../icon-final/layers/01-background.svg" width="1024" height="1024" style="top:0">'
    '<img src="../../../icon-final/layers/02-glass-2.svg" width="1024" height="1024" style="top:1024px">'
    '<img src="../../../icon-final/layers/03-glyph.svg" width="1024" height="1024" style="top:2048px">'
    '<img src="../../../icon-final/layers/01-background-dark.svg" width="1024" height="1024" style="top:3072px">'
    '</body></html>')
shot(os.path.join(CANVAS, "_layers.html"), os.path.join(CANVAS, "_layers.png"), 1024, 4096, transparent=True)
lp = Image.open(os.path.join(CANVAS, "_layers.png")).convert("RGBA")
for i, name in enumerate(["01-background.png", "02-glass-2.png", "03-glyph.png", "01-background-dark.png"]):
    lp.crop((0, 1024 * i, 1024, 1024 * (i + 1))).save(os.path.join(LAYERS, name), "PNG", optimize=True)

# ---------------------------------------------------------------- canvas / overview
EXTRA_CSS = """
.f2{width:1200px}
.fam{width:300px;height:390px;border-radius:20px;background:#EDEDF0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px}
.fam .arr{font-size:22px;color:#A1A1A6;line-height:1}
.ap5 .t{width:230px;height:230px}
.strip3{width:355px;height:200px}
.note{font:500 12px/18px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;margin-top:10px}
.mani{font:500 12px/20px ui-monospace,"SF Mono",Menlo,monospace;color:#3A3A3C;background:#EDEDF0;border-radius:14px;padding:16px 20px;white-space:pre-wrap}
"""
CSS = gen.CSS + EXTRA_CSS
img = gen.img

def strip(cls, files, dark=False):
    inner = "".join(f'<div class="s">{img(src, s, "")}<span>{s}</span></div>' for src, s in files)
    return f'<div class="strip strip3 {cls}">{inner}</div>'

def lay(n, m, src):
    return (f'<div class="l"><div class="box">{img(src, 170)}</div><div class="n">{n}</div><div class="m">{m}</div></div>')

def final_frame(standalone=False):
    p = "final/"
    pos = "" if standalone else "left:0px;top:0px;"
    label = "" if standalone else '<div class="fl" data-drags-parent="1">C · Glass 2 · 最终稿</div>'
    manifest = """icon-final/
├─ layers/            Icon Composer 图层：01-background(.svg/.png, +dark)、02-glass-2、03-glyph；README.md 写材质与 IC 设置
├─ MacDown2.icon/     Icon Composer 包（icon.json + Assets/），可直接拖进 Xcode 26
├─ appiconset/        AppIcon.appiconset：16–512 @1x/@2x 共 10 张 PNG + Contents.json（16/32 用无「2」小尺寸版）
├─ svg/               合成稿：C-light / C-dark / C-small-light / C-small-dark
└─ macdown2-icon-C-final-overview.png"""
    return f"""
<div class="frame f2" data-screen-label="C 最终稿" style="{pos}height:1760px">
  {label}
  <div class="eyebrow">MacDown2.0 · App Icon · 方向 C · 最终稿</div>
  <div class="h2">Glass 2 — Final</div>
  <p class="sub">在概念稿基础上细化：M↓ 放大到 3.9×并重新定位，玻璃「2」加粗到 24 并提高到 26% 不透明度，128px 以上「2」清楚可辨；16 / 32px 改用无「2」的小尺寸版（M↓ 居中放大），避免玻璃层在小尺寸糊成脏色块；Light / Dark / Clear / Tinted 四种外观逐一核对；图层拆为背景渐变、玻璃「2」、M↓ 字形三层，另附 .icon 包与传统 appiconset 兜底。</p>

  <div class="sec">主图 · 1024 画布 · 824 squircle</div>
  <div class="row">
    <div><div class="hero lt">{img(p + "C-light.svg", 300)}</div><div class="cap">Light（默认）</div></div>
    <div><div class="hero dk">{img(p + "C-dark.svg", 300)}</div><div class="cap">Dark</div></div>
    <div><div class="fam">{img("final/orig-128.png", 128)}<div class="arr">↓</div>{img(p + "C-light.svg", 128)}</div><div class="cap">原版 → 新一代 · 同一家族</div></div>
  </div>

  <div class="sec">四种外观 · Light / Dark / Clear / Tinted（后两种为系统派生示意）</div>
  <div class="ap ap5">
    <div><div class="t lt">{img(p + "C-light.svg", 180)}</div><div class="cap">Light</div></div>
    <div><div class="t dk">{img(p + "C-dark.svg", 180)}</div><div class="cap">Dark</div></div>
    <div><div class="t w">{img(p + "C-clear.svg", 230, "")}</div><div class="cap">Clear</div></div>
    <div><div class="t w">{img(p + "C-tinted.svg", 230, "")}</div><div class="cap">Tinted</div></div>
  </div>

  <div class="sec">小尺寸 · 原版 vs 最终稿（1× CSS px；16 / 32 为无「2」版，64px 起带「2」）</div>
  <div class="row">
    <div>{strip("lt", [("final/orig-16.png", 16), ("final/orig-32.png", 32), ("final/orig-128.png", 128)])}<div class="cap">原版 MacDown</div></div>
    <div>{strip("lt", [(p + "C-small-light.svg", 16), (p + "C-small-light.svg", 32), (p + "C-light.svg", 128)])}<div class="cap">最终稿 · Light</div></div>
    <div>{strip("dk", [(p + "C-small-dark.svg", 16), (p + "C-small-dark.svg", 32), (p + "C-dark.svg", 128)])}<div class="cap">最终稿 · Dark</div></div>
  </div>

  <div class="sec">图层 · Icon Composer（层级自下而上）</div>
  <div class="lay">
    {lay("L1 背景渐变", "对角线性渐变 #5EEAEA → #1A8BDC → #0B3AA6；不透明；Dark 外观换深色停驻点", p + "C-l1.svg")}
    <div class="plus">+</div>
    {lay("L2 玻璃「2」", "白色描边字形；Translucency ≈ 0.7、Blur on、Specular on、Shadow off；呈现为 ~26% 磨砂玻璃", p + "C-l2.svg")}
    <div class="plus">+</div>
    {lay("L3 字形 M↓", "白色实心；Specular on、Shadow neutral ≈ 0.5、Translucency off；始终最上层", p + "C-l3.svg")}
  </div>

  <div class="sec">交付清单</div>
  <div class="mani">{manifest}</div>
</div>"""

HEAD = f'<!DOCTYPE html><html><head><meta charset="utf-8"><title>MacDown2.0 Icon Final</title><style>{CSS}</style></head><body>'
put(os.path.join(CANVAS, "export-final.html"),
    HEAD + '<div style="position:relative;width:1200px;height:1760px">' + final_frame(standalone=True) + "</div></body></html>")
shot(os.path.join(CANVAS, "export-final.html"), os.path.join(FINAL, "macdown2-icon-C-final-overview.png"), 1200, 1760, dpr=2)

DC = f"""<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <script src="./support.js"></script>
  </head>
  <body>
    <x-dc>
      <helmet data-dc-atomics>
        <meta name="design_doc_mode" content="canvas">
        <style>{CSS}</style>
      </helmet>
{final_frame()}
    </x-dc>
    <script
      type="text/x-dc"
      data-dc-script
      data-props='{{}}'
    >
      class Component extends DCLogic {{
        renderVals() {{ return {{}}; }}
      }}
    </script>
  </body>
</html>
"""
put(os.path.join(CANVAS, "C Final.dc.html"), DC)
print("final assets written:", FINAL)
