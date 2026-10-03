#!/usr/bin/env python3
"""Generate MacDown2.0 icon concepts: SVG icons, Claude Design canvas, export pages."""
import math, os, shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, "build")
ICONS = os.path.join(BUILD, "icons")
os.makedirs(ICONS, exist_ok=True)

# ---------------------------------------------------------------- geometry
C, R = 512, 412  # macOS icon grid: 824px squircle centered on a 1024 canvas

def squircle(n=4.6, pts=120):
    pts_abs = []
    for i in range(pts):
        t = 2 * math.pi * i / pts
        c, s = math.cos(t), math.sin(t)
        x = C + R * math.copysign(abs(c) ** (2 / n), c)
        y = C + R * math.copysign(abs(s) ** (2 / n), s)
        pts_abs.append((round(x), round(y)))
    out = [f"M{pts_abs[0][0]},{pts_abs[0][1]}"]
    for (x0, y0), (x1, y1) in zip(pts_abs, pts_abs[1:]):
        if (x1 - x0, y1 - y0) != (0, 0):
            out.append(f"l{x1 - x0},{y1 - y0}")
    return "".join(out) + "Z"

SQ = squircle()

# Markdown Mark letterforms (Dustin Curtis, CC0) in its native 208x128 space.
MARK_M = "M30 98V30h20l20 25 20-25h20v68H90V59L70 84 50 59v39z"
MARK_ARROW = "M155 98l-30-33h20V30h20v35h20z"
# Direction B: solid arrow + a second chevron band (own drawing, same grid).
B_ARROW = "M146 28h18v26h21L155 76 125 54h21z"
B_BAND = "M125 64 155 86 185 64v12L155 98 125 76z"
# Numeral "2", stroke-drawn in a 100x100 box (arc, diagonal, base).
TWO = "M18 34A32 32 0 1 1 74 56L18 100H100"

# ---------------------------------------------------------------- palettes
DIRS = {
    "A": dict(
        name="Glass M↓²", tag="演进", eyebrow="方向 A · 最接近原版的演进",
        light=[("0", "#48E1E3"), ("0.55", "#22B3DE"), ("1", "#1286D3")],
        dark=[("0", "#1B96C4"), ("0.55", "#0F69A8"), ("1", "#0A3B78")],
        angle=(0, 0, 0, 1),
        desc=("构图、色相、字形全部沿用原版：青→蓝纵向渐变的方形承载白色 M↓。"
              "去掉 Big Sur 时代的 3D 浮雕，字形改为单层平面玻璃（高光交给 Icon Composer 的 specular），"
              "渐变重调到 macOS 26 的亮度区间，并在字形后加一圈柔光。"
              "「新一代」只用一个动作表达：箭头右上加一个小小的 ²，读作 MacDown²；小尺寸时它自然隐去，只剩熟悉的 M↓。"),
        layers=[("L1 背景", "纵向渐变 + 柔光；不透明"),
                ("L2 字形 M↓", "白色平面玻璃；specular on、shadow on"),
                ("L3 上标 ²", "同材质；小尺寸可由系统自动淡出")],
        diff=["浮雕 3D 字形 → 单层玻璃字形", "底部渐变更深、字形后加柔光", "新增上标 ²（唯一的新元素）"],
    ),
    "B": dict(
        name="Double Down", tag="平衡", eyebrow="方向 B · 平衡方案",
        light=[("0", "#52E5E4"), ("0.5", "#1F97DA"), ("1", "#1156C6")],
        dark=[("0", "#1C9CC9"), ("0.5", "#0E5EA8"), ("1", "#082A66")],
        angle=(0, 0, 1, 1),
        desc=("保留 M 和整体比例，把 ↓ 改为「实心箭头 + 第二道 chevron」：既是「2」，也是「下一代 / 更快」。"
              "背景换成对角双色渐变，并加一片斜向玻璃折面作为独立图层，暗合左编辑 / 右预览的分栏。"
              "32px 起双箭头清晰可辨；16px 退化成一块箭头形，仍与家族一致。"),
        layers=[("L1 背景", "对角渐变；不透明"),
                ("L2 玻璃折面", "白色 10% + 边缘高光；translucency on"),
                ("L3 字形 M⇓", "白色平面玻璃；specular on、shadow on")],
        diff=["单箭头 → 实心箭头 + 第二道 chevron", "纵向渐变 → 对角双色 + 斜向折面", "折面是独立图层，clear 外观里成为唯一的背景线索"],
    ),
    "C": dict(
        name="Glass 2", tag="新一代", eyebrow="方向 C · 最大胆的新一代",
        light=[("0", "#5EEAEA"), ("0.45", "#1A8BDC"), ("1", "#0B3AA6")],
        dark=[("0", "#1F9FCC"), ("0.45", "#0D56A5"), ("1", "#061B54")],
        angle=(0, 0, 1, 1),
        desc=("三层结构：深邃的对角渐变背景 → 一枚半透明磨砂玻璃的巨型「2」→ 前景白色 M↓。"
              "「2」靠右下、被方形边缘裁切，像嵌在冰里的数字；色域向靛蓝延伸，和原版的浅青拉开距离，M↓ 略向左上偏移给「2」让出重心。"
              "Liquid Glass 原生：「2」图层开 translucency + blur 后会折射背景，clear / tinted 外观里只剩一道轮廓光。"),
        layers=[("L1 背景", "对角深渐变；不透明"),
                ("L2 玻璃「2」", "白色 22% + 顶缘高光；translucency + blur on"),
                ("L3 字形 M↓", "白色平面玻璃；specular on、shadow on")],
        diff=["新增巨型玻璃「2」图层，被边缘裁切", "色域从浅青延伸到靛蓝，对角渐变", "M↓ 偏移到左上，不再居中"],
    ),
}

TINT = "#5EDAEE"

# ---------------------------------------------------------------- SVG pieces
def grad(gid, stops, angle):
    x1, y1, x2, y2 = angle
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'

DEFS_COMMON = f"""
<clipPath id="sq"><path d="{SQ}"/></clipPath>
<linearGradient id="gw" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E3F2FA"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.47" r="0.5"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.36"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#04305F" flood-opacity="0.36"/></filter>
<filter id="dsn" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000000" flood-opacity="0.22"/></filter>
<filter id="glowt" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="0" stdDeviation="22" flood-color="{TINT}" flood-opacity="0.45"/></filter>
<filter id="rim" x="-20%" y="-20%" width="140%" height="140%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="9" result="b"/>
  <feOffset in="b" dx="7" dy="11" result="o"/>
  <feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/>
  <feFlood flood-color="#FFFFFF" flood-opacity="0.75" result="f"/>
  <feComposite in="f" in2="edge" operator="in" result="rimc"/>
  <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="rimc"/></feMerge>
</filter>
<filter id="blur60"><feGaussianBlur stdDeviation="60"/></filter>
"""

def wallpaper(mode):
    if mode == "clear":
        return ('<rect width="1024" height="1024" fill="url(#wp)"/>'
                '<g filter="url(#blur60)"><circle cx="210" cy="260" r="360" fill="#BBD7FF" fill-opacity="0.85"/>'
                '<circle cx="840" cy="820" r="400" fill="#FFD3E4" fill-opacity="0.85"/>'
                '<circle cx="760" cy="150" r="220" fill="#C6F3EC" fill-opacity="0.7"/></g>')
    return ('<rect width="1024" height="1024" fill="url(#wp)"/>'
            '<g filter="url(#blur60)"><circle cx="230" cy="260" r="360" fill="#2B3C66" fill-opacity="0.9"/>'
            '<circle cx="830" cy="830" r="400" fill="#3B2A4F" fill-opacity="0.9"/>'
            '<circle cx="760" cy="150" r="220" fill="#1E4044" fill-opacity="0.8"/></g>')

WP_LIGHT = '<linearGradient id="wp" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E8EEF6"/><stop offset="1" stop-color="#F4E9F1"/></linearGradient>'
WP_DARK = '<linearGradient id="wp" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1E222B"/><stop offset="1" stop-color="#0E1016"/></linearGradient>'

def glyph_group(d, mode):
    """Foreground letterform layer (L2 for A, L3 for B/C)."""
    if mode == "tinted":
        fill, filt, stroke = TINT, "url(#glowt)", TINT
    elif mode == "clear":
        fill, filt, stroke = "#FFFFFF", "url(#dsn)", "#FFFFFF"
    else:
        fill, filt, stroke = "url(#gw)", "url(#ds)", "#FFFFFF"
    op = ' opacity="0.96"' if mode == "clear" else ""
    if d == "A":
        tf, paths = "translate(52,256) scale(4)", [MARK_M, MARK_ARROW]
    elif d == "B":
        tf, paths = "translate(60.5,243.2) scale(4.2)", [MARK_M, B_ARROW, B_BAND]
    else:
        tf, paths = "translate(66,150) scale(3.8)", [MARK_M, MARK_ARROW]
    body = "".join(f'<path d="{p}"/>' for p in paths)
    return (f'<g filter="{filt}"{op}><g transform="{tf}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="5" stroke-linejoin="round" paint-order="stroke">{body}</g></g>')

def two_small(mode):
    """A's superscript ²."""
    col = TINT if mode == "tinted" else "#FFFFFF"
    filt = "url(#glowt)" if mode == "tinted" else ("url(#dsn)" if mode == "clear" else "url(#ds)")
    return (f'<g filter="{filt}"><svg x="724" y="304" width="94" height="94" viewBox="-14 -14 128 128" overflow="visible">'
            f'<path d="{TWO}" fill="none" stroke="{col}" stroke-width="21" stroke-linecap="round" stroke-linejoin="round"/></svg></g>')

def two_big(mode):
    """C's glass numeral."""
    if mode == "tinted":
        col, op = TINT, "0.22"
    elif mode == "clear":
        col, op = "#FFFFFF", "0.42"
    else:
        col, op = "#FFFFFF", "0.25"
    return (f'<g clip-path="url(#sq)"><g filter="url(#rim)"><svg x="496" y="384" width="548" height="548" viewBox="-14 -14 128 128" overflow="visible">'
            f'<path d="{TWO}" fill="none" stroke="{col}" stroke-opacity="{op}" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/></svg></g></g>')

def facet(mode):
    """B's diagonal glass facet."""
    col = TINT if mode == "tinted" else "#FFFFFF"
    op = "0.08" if mode == "tinted" else ("0.30" if mode == "clear" else "0.11")
    return (f'<g clip-path="url(#sq)"><g filter="url(#rim)"><path d="M0 0H1024L0 1024Z" fill="{col}" fill-opacity="{op}"/></g></g>')

def bg_layer(d, mode):
    cfg = DIRS[d]
    if mode in ("light", "dark"):
        g = f'<rect width="1024" height="1024" fill="url(#bg)"/>'
        if d == "A":
            g += '<ellipse cx="512" cy="480" rx="430" ry="270" fill="url(#glow)"/>'
        return f'<g clip-path="url(#sq)">{g}</g>'
    if mode == "clear":
        return (f'<g clip-path="url(#sq)"><rect width="1024" height="1024" fill="#FFFFFF" fill-opacity="0.42"/>'
                f'<path d="{SQ}" fill="none" stroke="#FFFFFF" stroke-opacity="0.8" stroke-width="6"/></g>')
    return (f'<g clip-path="url(#sq)"><rect width="1024" height="1024" fill="#1B1D24" fill-opacity="0.8"/>'
            f'<path d="{SQ}" fill="none" stroke="#FFFFFF" stroke-opacity="0.16" stroke-width="6"/></g>')

def mid_layer(d, mode):
    return {"A": two_small, "B": facet, "C": two_big}[d](mode)

OUTLINE = f'<path d="{SQ}" fill="none" stroke="#FFFFFF" stroke-opacity="0.28" stroke-width="3" stroke-dasharray="14 12"/>'

def build_svg(d, variant):
    """variant: light | dark | clear | tinted | l1 | l2 | l3"""
    cfg = DIRS[d]
    mode = variant if variant in ("light", "dark", "clear", "tinted") else "light"
    defs = DEFS_COMMON + grad("bg", cfg["dark"] if mode == "dark" else cfg["light"], cfg["angle"])
    defs += WP_LIGHT if mode == "clear" else WP_DARK
    body = ""
    if variant in ("clear", "tinted"):
        body += wallpaper(variant)
    # layer order per direction: A = bg, glyph, ²  |  B/C = bg, mid, glyph
    order = ["bg", "glyph", "mid"] if d == "A" else ["bg", "mid", "glyph"]
    want = {"l1": {"bg"}, "l2": {order[1]}, "l3": {order[2]}}.get(variant, set(order))
    for layer in order:
        if layer not in want:
            continue
        body += {"bg": lambda: bg_layer(d, mode), "mid": lambda: mid_layer(d, mode), "glyph": lambda: glyph_group(d, mode)}[layer]()
    if variant in ("l1", "l2", "l3"):
        body += OUTLINE
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{body}</svg>')

VARIANTS = ["light", "dark", "clear", "tinted", "l1", "l2", "l3"]
for d in DIRS:
    for v in VARIANTS:
        with open(os.path.join(ICONS, f"{d}-{v}.svg"), "w") as f:
            f.write(build_svg(d, v))

from PIL import Image
Image.open(os.path.join(ROOT, "..", "md3k", "MacDown", "Images.xcassets", "AppIcon.appiconset", "icon_256x256.png")).save(
    os.path.join(BUILD, "original-macdown-256.webp"), "WEBP", quality=92, method=6)

# ---------------------------------------------------------------- HTML
CSS = """
*{box-sizing:border-box}
body{margin:0;background:#E9E9EC;font-family:-apple-system,"SF Pro Text","PingFang SC","Helvetica Neue",system-ui,sans-serif;color:#1D1D1F;-webkit-font-smoothing:antialiased}
a{color:#1286D3}a:hover{color:#0A3B78}
.frame{position:absolute;background:#F7F7F8;border:1px solid #D9D9DE;border-radius:28px;padding:40px;width:900px}
.ov{width:2780px;height:700px}
.fl{position:absolute;left:0;top:-36px;font:500 13px/18px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;letter-spacing:.02em;text-transform:uppercase}
.eyebrow{font:600 12px/16px ui-monospace,"SF Mono",Menlo,monospace;color:#1286D3;letter-spacing:.06em;text-transform:uppercase}
.h1{font-size:40px;line-height:46px;font-weight:700;letter-spacing:-.02em;margin:8px 0 0}
.h2{font-size:30px;line-height:36px;font-weight:700;letter-spacing:-.02em;margin:6px 0 0}
.sub{font-size:15px;line-height:24px;color:#3A3A3C;margin:14px 0 0;max-width:820px;text-wrap:pretty}
.sec{font:600 12px/16px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;letter-spacing:.06em;text-transform:uppercase;margin:34px 0 12px}
.row{display:flex;gap:40px}
.hero{width:390px;height:390px;border-radius:20px;display:flex;align-items:center;justify-content:center}
.lt{background:#EDEDF0}.dk{background:#131315}.mid{background:#3A3C42}
.ic{display:block;filter:drop-shadow(0 10px 22px rgba(0,0,0,.16))}
.cap{font:500 12px/16px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;text-align:center;margin-top:10px}
.capd{color:#B5B5BA}
.ap{display:flex;gap:26px}
.ap .t{width:185px;height:185px;border-radius:18px;display:flex;align-items:center;justify-content:center;overflow:hidden}
.ap .t .ic{filter:drop-shadow(0 6px 14px rgba(0,0,0,.14))}
.ap .w{background:none}
.strip{display:flex;align-items:flex-end;gap:36px;border-radius:16px;padding:22px 28px 18px;width:390px;height:190px}
.strip .s{display:flex;flex-direction:column;align-items:center;gap:8px}
.strip .s img{display:block}
.strip .s span{font:500 11px/14px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73}
.dk .s span{color:#B5B5BA}
.lay{display:flex;align-items:flex-start;gap:0}
.lay .l{width:250px;display:flex;flex-direction:column;align-items:center}
.lay .l .box{width:200px;height:200px;border-radius:18px;background:#3A3C42;display:flex;align-items:center;justify-content:center}
.lay .l .n{font-size:13px;line-height:18px;font-weight:600;margin-top:12px}
.lay .l .m{font:500 11px/15px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;text-align:center;margin-top:4px;text-wrap:pretty;padding:0 10px}
.lay .plus{width:35px;height:200px;display:flex;align-items:center;justify-content:center;font-size:26px;color:#A1A1A6}
.cmp{display:flex;align-items:center;gap:32px}
.cmp .c{display:flex;flex-direction:column;align-items:center;gap:8px}
.cmp .c span{font:500 11px/14px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73}
.cmp .arr{font-size:30px;color:#A1A1A6}
.cmp ul{margin:0 0 0 12px;padding:0 0 0 18px;font-size:14px;line-height:22px;color:#3A3A3C}
.cmp ul li{margin:2px 0}
.ovrow{display:flex;gap:72px;align-items:flex-start;margin-top:40px}
.ovrow .o{display:flex;flex-direction:column;align-items:center;gap:14px;width:380px}
.ovrow .o .tile{width:380px;height:380px;border-radius:28px;display:flex;align-items:center;justify-content:center}
.ovrow .o .nm{font-size:16px;font-weight:600}
.ovrow .o .nm small{display:block;font:500 11px/16px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;font-weight:500;margin-top:2px;text-align:center}
.ovmeta{position:absolute;right:40px;top:236px;width:900px;font-size:14px;line-height:22px;color:#3A3A3C;text-wrap:pretty}
.ovmeta b{font-weight:600}
.ovmeta .k{font:600 11px/16px ui-monospace,"SF Mono",Menlo,monospace;color:#6E6E73;letter-spacing:.06em;text-transform:uppercase;margin-bottom:6px}
"""

def img(src, size, cls="ic"):
    return f'<img class="{cls}" src="{src}" width="{size}" height="{size}" alt="">'

def direction_frame(d, left, top, standalone=False):
    cfg = DIRS[d]
    p = "icons/"
    L = cfg["layers"]
    layer_html = ""
    for i, (n, m) in enumerate(L):
        if i:
            layer_html += '<div class="plus">+</div>'
        layer_html += (f'<div class="l"><div class="box">{img(p + f"{d}-l{i+1}.svg", 170)}</div>'
                       f'<div class="n">{n}</div><div class="m">{m}</div></div>')
    diffs = "".join(f"<li>{x}</li>" for x in cfg["diff"])
    pos = "" if standalone else f'left:{left}px;top:{top}px;'
    label = "" if standalone else f'<div class="fl" data-drags-parent="1">方向 {d} · {cfg["name"]}</div>'
    return f"""
<div class="frame" data-screen-label="方向 {d} {cfg['name']}" style="{pos}height:1780px">
  {label}
  <div class="eyebrow">{cfg['eyebrow']}</div>
  <div class="h2">{cfg['name']}</div>
  <p class="sub">{cfg['desc']}</p>

  <div class="sec">主图 · 1024 画布 · 824 squircle</div>
  <div class="row">
    <div><div class="hero lt">{img(p + f"{d}-light.svg", 300)}</div><div class="cap">Light（默认）</div></div>
    <div><div class="hero dk">{img(p + f"{d}-dark.svg", 300)}</div><div class="cap">Dark</div></div>
  </div>

  <div class="sec">四种外观 · Light / Dark / Clear / Tinted（后两种为系统派生示意）</div>
  <div class="ap">
    <div><div class="t lt">{img(p + f"{d}-light.svg", 150)}</div><div class="cap">Light</div></div>
    <div><div class="t dk">{img(p + f"{d}-dark.svg", 150)}</div><div class="cap">Dark</div></div>
    <div><div class="t w">{img(p + f"{d}-clear.svg", 185, "")}</div><div class="cap">Clear</div></div>
    <div><div class="t w">{img(p + f"{d}-tinted.svg", 185, "")}</div><div class="cap">Tinted</div></div>
  </div>

  <div class="sec">小尺寸 · 16 / 32 / 128（1× CSS px）</div>
  <div class="row">
    <div class="strip lt">
      <div class="s">{img(p + f"{d}-light.svg", 16, "")}<span>16</span></div>
      <div class="s">{img(p + f"{d}-light.svg", 32, "")}<span>32</span></div>
      <div class="s">{img(p + f"{d}-light.svg", 128, "")}<span>128</span></div>
    </div>
    <div class="strip dk">
      <div class="s">{img(p + f"{d}-dark.svg", 16, "")}<span>16</span></div>
      <div class="s">{img(p + f"{d}-dark.svg", 32, "")}<span>32</span></div>
      <div class="s">{img(p + f"{d}-dark.svg", 128, "")}<span>128</span></div>
    </div>
  </div>

  <div class="sec">图层拆分 · 供 Icon Composer 组装 .icon</div>
  <div class="lay">{layer_html}</div>

  <div class="sec">与原版对比</div>
  <div class="cmp">
    <div class="c">{img("original-macdown-256.webp", 128)}<span>原版 MacDown</span></div>
    <div class="arr">→</div>
    <div class="c">{img(p + f"{d}-light.svg", 128)}<span>方向 {d}</span></div>
    <ul>{diffs}</ul>
  </div>
</div>"""

def overview_frame(standalone=False):
    pos = "" if standalone else "left:0px;top:0px;"
    label = "" if standalone else '<div class="fl" data-drags-parent="1">总览</div>'
    tiles = (f'<div class="o"><div class="tile lt">{img("original-macdown-256.webp", 300)}</div>'
             f'<div class="nm">原版 MacDown<small>MacDownApp/macdown · macdown3000 同一文件</small></div></div>')
    for d, cfg in DIRS.items():
        tiles += (f'<div class="o"><div class="tile lt">{img(f"icons/{d}-light.svg", 300)}</div>'
                  f'<div class="nm">{d} · {cfg["name"]}<small>{cfg["tag"]}</small></div></div>')
    return f"""
<div class="frame ov" data-screen-label="总览" style="{pos}">
  {label}
  <div class="eyebrow">MacDown2.0 · App Icon · macOS 26</div>
  <div class="h1">三个方向</div>
  <p class="sub">沿用 MacDown 家族的视觉语言——青蓝渐变方形 + 白色 Markdown Mark「M↓」——重新绘制并分层，适配 Liquid Glass。所有方案都是 1024 画布、824 连续曲率 squircle，背景层与字形层分离，可直接进 Icon Composer。</p>
  <div class="ovmeta">
    <div class="k">来源与许可</div>
    <b>原版图标</b>：MacDown（MIT，Tzu-ping Chung；图标作者 Matt Zanchelli），macdown3000 克隆里的 AppIcon.appiconset 与上游 master 的文件逐字节相同。<br>
    <b>「M↓」字形</b>：Dustin Curtis 的 Markdown Mark，CC0 公共领域，可自由改绘。<br>
    <b>本稿</b>：未复用原图任何像素；字形按 Markdown Mark 网格重绘并圆角化，背景、材质、「2」均为新绘。
  </div>
  <div class="ovrow">{tiles}</div>
</div>"""

HEAD_PLAIN = f'<!DOCTYPE html><html><head><meta charset="utf-8"><title>MacDown2.0 Icon</title><style>{CSS}</style></head><body>'

# standalone export pages (local screenshot)
def export_page(inner, w, h):
    return (HEAD_PLAIN + f'<div style="position:relative;width:{w}px;height:{h}px;padding:0">'
            + inner + "</div></body></html>")

with open(os.path.join(BUILD, "export-overview.html"), "w") as f:
    f.write(export_page(overview_frame(standalone=True), 2780, 700))
for d in DIRS:
    with open(os.path.join(BUILD, f"export-{d}.html"), "w") as f:
        f.write(export_page(direction_frame(d, 0, 0, standalone=True), 900, 1780))

# Claude Design canvas (.dc.html)
canvas_body = overview_frame() + "".join(direction_frame(d, i * 940, 800) for i, d in enumerate(DIRS))
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
{canvas_body}
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
with open(os.path.join(BUILD, "MacDown2.0 App Icon.dc.html"), "w") as f:
    f.write(DC)
print("built", len(os.listdir(ICONS)), "icons")
