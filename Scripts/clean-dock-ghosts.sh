#!/bin/sh
# Swift test runners started from a terminal leave dead Dock tiles named after the terminal app (seen on macOS 27).
# Restart the Dock only when an app shows more tiles than its running instances / pinned tile. Never fails the build.
dock=$(osascript -e 'tell application "System Events" to tell process "Dock" to get name of every UI element of list 1' 2>/dev/null) || exit 0
running=$(lsappinfo list 2>/dev/null | awk -F'"' '/^ *[0-9]+\) "/{print $2}')
pinned=$(defaults read com.apple.dock persistent-apps 2>/dev/null | awk -F' = ' '/"file-label"/{gsub(/[";]/,"",$2); print $2}')
printf '%s\n' "$dock" | tr ',' '\n' | sed 's/^ *//' | sort | uniq -c | while read -r n name; do
  r=$(printf '%s\n' "$running" | grep -cxF "$name")
  p=$(printf '%s\n' "$pinned" | grep -cxF "$name")
  if [ $((r + p)) -gt 0 ] && [ "$n" -gt "$((r > p ? r : p))" ]; then
    echo "clean-dock-ghosts: $n '$name' tiles for $r running; restarting Dock"
    killall Dock
    break
  fi
done
exit 0
