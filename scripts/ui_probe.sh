#!/usr/bin/env bash
# Headless X11 probe: run the IDE under Xvfb and capture screenshots.
# Usage: scripts/ui_probe.sh [xvfb|xwayland]
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/generated/ui"
MODE="${1:-xvfb}"
mkdir -p "$OUT"
PROJECT="${CAMPY_PROJECT:-$ROOT/examples/demo}"

cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "${WM_PID:-}" ]] && kill "$WM_PID" 2>/dev/null || true
  [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$MODE" == "xvfb" ]]; then
  Xvfb :99 -screen 0 1400x900x24 >/dev/null 2>&1 & XVFB_PID=$!
  export DISPLAY=:99
  sleep 1
  openbox >/dev/null 2>&1 & WM_PID=$!
  sleep 1
else
  export DISPLAY="${DISPLAY:-:0}"
fi
export GDK_BACKEND=x11

(
  cd "$ROOT/gleam/apps/campy_ide_wx"
  exec gleam run
) >"$OUT/app.log" 2>&1 & APP_PID=$!

win=""
for _ in $(seq 1 80); do
  win=$(xdotool search --name '^Campy' 2>/dev/null | head -1 || true)
  [ -n "$win" ] && break
  sleep 0.5
done
if [ -z "$win" ]; then
  echo "no window; app log:" >&2
  tail -30 "$OUT/app.log" >&2
  exit 1
fi

xdotool windowactivate --sync "$win" 2>/dev/null || true
sleep 2
echo "win=$win"
xdotool getwindowgeometry "$win"
shot() { import -window "$win" "$OUT/$1.png"; echo "shot=$OUT/$1.png"; }
click() { xdotool mousemove --window "$win" "$1" "$2" click 1; sleep 1; }

shot initial
click 263 107
click 400 300
shot empty-click
click 300 140
shot selected-label
click 300 166
shot selected-text
# resize via the south-east handle (+40, +12)
xdotool mousemove --window "$win" 820 178 mousedown 1
xdotool mousemove_relative --sync 40 12
xdotool mouseup 1
sleep 1
shot resized-text
# move via the grip (+30, +30)
xdotool mousemove --window "$win" 520 140 mousedown 1
xdotool mousemove_relative --sync 30 30
xdotool mouseup 1
sleep 1
shot moved-text
# expand the tree, switch modules, come back: geometry must persist
click 14 103
shot tree-expanded
click 70 125
click 70 147
click 70 125
shot module-return
