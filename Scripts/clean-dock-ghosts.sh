#!/bin/sh
# Short-lived GUI processes started from a terminal (osascript above all) leave dead Dock tiles named after the terminal
# app on macOS 27. Restart the Dock only when an app shows more tiles than its running instances / pinned tile.
# Never fails the build. The tiles are read with Scripts/dock-tiles.swift, not osascript, which would add a ghost itself.
cd "$(dirname "$0")/.." || exit 0
tool=build/dock-tiles
if [ ! -x "$tool" ] || [ Scripts/dock-tiles.swift -nt "$tool" ]; then
  mkdir -p build && swiftc -O Scripts/dock-tiles.swift -o "$tool" 2>/dev/null || exit 0
fi
dock=$("$tool" "$(pgrep -x Dock)" 2>/dev/null) || exit 0
running=$(lsappinfo list 2>/dev/null | awk -F'"' '/^ *[0-9]+\) "/{print $2}')
pinned=$(defaults read com.apple.dock persistent-apps 2>/dev/null | awk -F' = ' '/"file-label"/{gsub(/[";]/,"",$2); print $2}')
printf '%s\n' "$dock" | sort | uniq -c | while read -r n name; do
  # Only terminals/editors that run the tools grow ghosts; other apps may legitimately show two tiles (pinned + a web app).
  case "$name" in Warp|Terminal|iTerm|iTerm2|Ghostty|"Visual Studio Code"|Cursor) ;; *) continue ;; esac
  r=$(printf '%s\n' "$running" | grep -cxF "$name")
  p=$(printf '%s\n' "$pinned" | grep -cxF "$name")
  if [ $((r + p)) -gt 0 ] && [ "$n" -gt "$((r > p ? r : p))" ]; then
    echo "clean-dock-ghosts: $n '$name' tiles for $r running; restarting Dock"
    killall Dock
    break
  fi
done
exit 0
