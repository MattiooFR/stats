#!/bin/zsh
# Review the popups without showing them: runs the Debug build for a few seconds with every popup opened
# under the wallpaper (STATS_DEBUG_POPUPS), captures each popup window and the menu bar widgets as PNG.
# Only a second set of menu bar items is visible while it runs.
#
#   dev-tools/snap.sh [seconds of data to wait] ["Key=value;Key=value"]
#
# The second argument is a list of settings applied in memory for this run only (STATS_DEBUG_OVERRIDES),
# e.g. "Disk_state=true;Sensors_state=true;CPU_processes=5;CPU_widget=bar_chart".
# The side panels (history shown on hover) are captured too, as detail-<Module>-<id>.png. The run reads the
# history kept by the installed app and never writes it; STATS_DEBUG_HISTORY=seed draws a made up curve instead.
# STATS_DEBUG_ONLY=CPU opens that popup alone (to check what it shows of another module, like its GPU card).
# Build first:
#   xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Debug -derivedDataPath build/dd \
#     -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
ROOT=${0:A:h:h}
WAIT=${1:-10}
OVERRIDES=${2:-}
APP="$ROOT/build/dd/Build/Products/Debug/Stats.app/Contents/MacOS/Stats"
OUT="$ROOT/build/shots/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
STATS_DEBUG_ONLY="${STATS_DEBUG_ONLY:-}" STATS_DEBUG_HISTORY="${STATS_DEBUG_HISTORY:-}" STATS_DEBUG_OVERRIDES="$OVERRIDES" STATS_DEBUG_POPUPS="$OUT/ids.txt" "$APP" > "$OUT/run.log" 2>&1 &
PID=$!
for i in {1..15}; do
  /bin/sleep 1
  [ -s "$OUT/ids.txt" ] && break
done
/bin/sleep $WAIT
if [ -s "$OUT/ids.txt" ]; then
  while read -r name id; do
    [ -n "$id" ] && screencapture -x -o -l "$id" "$OUT/$name.png"
  done < <(cat "$OUT/ids.txt"; echo)
fi
kill $PID 2>/dev/null
echo "$OUT"
ls "$OUT"
