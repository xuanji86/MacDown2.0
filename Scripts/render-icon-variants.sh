#!/bin/bash
# Renders the app icon's four appearances into App/IconStyles/, the images Settings > General > "App 图标" shows and (via
# NSApp.applicationIconImage, see App/Settings/IconStyle.swift) puts in the Dock while the app runs. Re-run this whenever
# App/AppIcon.icon changes and commit the PNGs.
#
#   Scripts/render-icon-variants.sh            # needs Xcode with Icon Composer (ictool; override with ICTOOL=/path/to/ictool)
#                                              # and python3 with Pillow (pip3 install pillow)
#
# Light / Dark are the real Icon Composer renderings (ictool Default / Dark).
# Clear / Tinted are composited here from the same glyph + "2" layers, at the geometry icon.json gives them. ictool's own
# ClearLight / TintedDark renditions are the system's derivation rules (an opaque flat grey, a flat teal): a real Clear icon
# is translucent and a real Tinted one is recoloured against whatever is behind it, but the Dock draws an
# applicationIconImage as given with nothing behind it, so the materials are baked in instead:
#   clear  - frosted white-glass panel with a thin lit rim over a soft blue / mint / pink wash, white M↓ with a soft shadow,
#            a faint translucent white 2
#   tinted - near-black navy glass panel over faint blue / teal / violet blooms, cyan M↓ with a glow, muted slate 2
# The squircle outline is taken from ictool's own 1024 rendering, so all four share one mask; outside it stays transparent.
# 384 px keeps the four files under 1 MB; the Dock and the About panel never draw the icon larger than 256 px.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ictool="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
size=384
out="$root/App/IconStyles"
[ -x "$ictool" ] || { echo "ictool not found at $ictool (install Xcode with Icon Composer, or set ICTOOL)" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "python3 with Pillow is required (pip3 install pillow)" >&2; exit 1; }
mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {  # output-file rendition width
  "$ictool" "$root/App/AppIcon.icon" --export-image --output-file "$1" --platform macOS \
    --rendition "$2" --width "$3" --height "$3" --scale 1 >/dev/null
  echo "$(basename "$1") ($2)"
}

render "$out/appicon-light.png" Default "$size"
render "$out/appicon-dark.png" Dark "$size"
render "$tmp/mask.png" Default 1024  # only its alpha is used: the full-bleed squircle

python3 - "$tmp/mask.png" "$root/App/AppIcon.icon/Assets" "$root/App/AppIcon.icon/icon.json" "$out" "$size" <<'PY'
import json, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

mask_png, assets, icon_json, out, size = sys.argv[1:6]
size = int(size)
N = 1024  # composited at the .icon's own 1024 canvas, then downscaled
mask = Image.open(mask_png).getchannel("A")  # the full-bleed squircle ictool itself draws
VGRAD = Image.linear_gradient("L").resize((N, N))  # black top -> white bottom


def blobs(base, spots):
    """A soft colour wash: blurred blobs (cx, cy, r, colour), all in 0..1 canvas units."""
    im = Image.new("RGB", (N, N), base)
    for cx, cy, r, col in spots:
        m = Image.new("L", (N, N), 0)
        ImageDraw.Draw(m).ellipse([(cx - r) * N, (cy - r) * N, (cx + r) * N, (cy + r) * N], fill=255)
        im.paste(Image.new("RGB", (N, N), col), (0, 0), m.filter(ImageFilter.GaussianBlur(r * N * 0.55)))
    return im


def scaled_mask(m, f):
    """The squircle mask scaled about the centre."""
    s = round(N * f)
    c = Image.new("L", (N, N), 0)
    c.paste(m.resize((s, s), Image.LANCZOS), ((N - s) // 2, (N - s) // 2))
    return c


def layer_art():
    """glyph + 2 exactly as AppIcon.icon places them (Glass 2's scale / translation come from icon.json)."""
    spec = next(l for g in json.load(open(icon_json))["groups"] if g["name"] == "Glass 2" for l in g["layers"])
    pos = spec.get("position", {})
    scale, (tx, ty) = pos.get("scale", 1), pos.get("translation-in-points", (0, 0))
    glyph = Image.open(f"{assets}/glyph.png").convert("RGBA")
    two = Image.open(f"{assets}/glass-2.png").convert("RGBA")
    s = round(N * scale)
    c = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    c.paste(two.resize((s, s), Image.LANCZOS), ((N - s) // 2 + round(tx), (N - s) // 2 + round(ty)))
    return glyph, c


def colour(col, a):
    """A flat colour layer with alpha channel a (an L image)."""
    return Image.merge("RGBA", (*Image.new("RGB", (N, N), col).split(), a))


def scale_alpha(a, k):
    return a.point(lambda v: round(v * k))


def finish(img, name):
    img.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    img.resize((size, size), Image.LANCZOS).save(f"{out}/appicon-{name}.png", optimize=True)


glyph, two = layer_art()
ga, ta = glyph.getchannel("A"), two.getchannel("A")
panel = scaled_mask(mask, 0.805)  # the standard 824 pt icon-grid squircle inside the 1024 canvas
rim = ImageChops.subtract(panel, scaled_mask(mask, 0.805 - 0.010))
two_a = ImageChops.multiply(ta, panel)  # the 2 is cut off by the panel edge, as in the design mockup


def rimmed(img, top, bottom, col):
    """A thin lit edge round the panel, brighter at the top like glass catching light."""
    a = VGRAD.point(lambda v: round(top + (bottom - top) * v / 255))
    img.alpha_composite(colour(col, ImageChops.multiply(a, rim)))


# --- Clear: frosted white glass, the pastel it would pick up from a desktop baked in -------------------------------
clear = blobs((240, 238, 245), [(0.02, 0.10, 0.42, (180, 206, 252)), (0.96, 0.02, 0.32, (196, 240, 234)),
                                (1.00, 0.95, 0.46, (250, 196, 216))]).convert("RGBA")
clear.alpha_composite(colour((255, 255, 255), ImageChops.multiply(VGRAD.point(lambda v: 100 - v // 6), panel)))
rimmed(clear, 255, 150, (255, 255, 255))
clear.alpha_composite(colour((255, 255, 255), scale_alpha(two_a, 0.62)))
clear.alpha_composite(colour((120, 110, 150), scale_alpha(ImageChops.offset(ga, 0, 16).filter(ImageFilter.GaussianBlur(9)), 0.34)))
clear.alpha_composite(colour((255, 255, 255), ga))
finish(clear, "clear")

# --- Tinted: near-black navy glass, cyan M↓ with a glow, slate 2 ---------------------------------------------------
tinted = blobs((22, 25, 34), [(0.10, 0.08, 0.42, (44, 58, 104)), (0.92, 0.04, 0.34, (34, 66, 66)),
                              (0.98, 0.92, 0.42, (58, 38, 78))]).convert("RGBA")
tinted.alpha_composite(colour((28, 31, 42), scale_alpha(panel, 0.80)))
rimmed(tinted, 120, 40, (170, 180, 200))
tinted.alpha_composite(colour((110, 128, 144), scale_alpha(two_a, 0.78)))
cyan = (90, 216, 238)
tinted.alpha_composite(colour(cyan, scale_alpha(ga.filter(ImageFilter.GaussianBlur(16)), 0.75)))
tinted.alpha_composite(colour(cyan, scale_alpha(ga.filter(ImageFilter.GaussianBlur(5)), 0.35)))
tinted.alpha_composite(colour(cyan, ga))
finish(tinted, "tinted")
PY
echo "appicon-clear.png, appicon-tinted.png (composited)"
du -ch "$out"/*.png | tail -1
