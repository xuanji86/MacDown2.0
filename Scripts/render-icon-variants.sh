#!/bin/bash
# Renders the app icon's four appearances from App/AppIcon.icon into App/IconStyles/, the images Settings > General > "App 图标"
# shows and (via NSApp.applicationIconImage, see App/Settings/IconStyle.swift) puts in the Dock while the app runs.
# They are the real Icon Composer renderings (ictool), not redrawn: re-run this whenever AppIcon.icon changes and commit the PNGs.
#
#   Scripts/render-icon-variants.sh            # needs Xcode with Icon Composer (ictool); override with ICTOOL=/path/to/ictool
#
# ictool renditions used: Default -> light, Dark -> dark, ClearLight -> clear, TintedDark -> tinted (cyan, hue/strength below).
# 384 px keeps the four files under 1 MB; the Dock and the About panel never draw the icon larger than 256 px.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ictool="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
size=384
out="$root/App/IconStyles"
[ -x "$ictool" ] || { echo "ictool not found at $ictool (install Xcode with Icon Composer, or set ICTOOL)" >&2; exit 1; }
mkdir -p "$out"

render() {  # name rendition [extra ictool args...]
  local name="$1" rendition="$2"; shift 2
  "$ictool" "$root/App/AppIcon.icon" --export-image --output-file "$out/appicon-$name.png" --platform macOS \
    --rendition "$rendition" --width "$size" --height "$size" --scale 1 "$@" >/dev/null
  echo "appicon-$name.png ($rendition)"
}

render light Default
render dark Dark
render clear ClearLight
render tinted TintedDark --tint-color 0.58 --tint-strength 0.75
du -ch "$out"/*.png | tail -1
