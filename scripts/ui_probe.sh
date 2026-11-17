#!/usr/bin/env bash
# Headless X11 probe: run the IDE under Xvfb and capture screenshots.
# Usage: scripts/ui_probe.sh [xvfb|xwayland]
#
# T2.5 recalibration: the window is 1280x860 and the probe screen is
# 1600x1000. Coordinates below are window-client coordinates (xdotool
# --window); they were read from the screenshots, not guessed.
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
  Xvfb :99 -screen 0 1600x1000x24 >/dev/null 2>&1 & XVFB_PID=$!
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
shot() { import -window root "$OUT/$1.png"; echo "shot=$OUT/$1.png"; }
click() { xdotool mousemove --window "$win" "$1" "$2" click 1; sleep 1; }
dblclick() {
  xdotool mousemove --window "$win" "$1" "$2" click --repeat 2 --delay 90 1
  sleep 0.7
}
type_text() { xdotool type --delay 80 "$1"; }

# --- T2.5: full shell ------------------------------------------------------
# 1280x860: menubar, text toolbar, 16-button palette strip, Projects/Modules
# navigator, centre Form/Code/Source + console, right Properties/Events dock.
shot t25-full-shell

# --- T2.1/T2.5: selection chrome and body drag ------------------------------
# The text control is at canvas (0,24), 600x28; canvas origin is client (202,194).
click 499 205
shot t25-selection-outline
# Drag the control body (not a handle) by 60x40. Screenshot mid-gesture to show
# the preview and the outline following it; then commit.
xdotool mousemove --window "$win" 499 205 mousedown 1
sleep 0.3
xdotool mousemove --sync --window "$win" 559 245
sleep 1
xdotool mouseup 1
sleep 1
shot t25-body-drag

# --- T2.3/T2.5: vertical property grid -------------------------------------
# One field per row; value column starts around client x=1119. Row order:
# id, kind, parent, x, y, w, h, text at client y 189..343 (22 px rows).
shot t25-inspector-properties
dblclick 1119 255
xdotool key ctrl+a
type_text "120"
xdotool key Return
sleep 1
shot t25-inspector-edit
# Undo/redo the inspector edit through the frame-level shortcuts.
xdotool key ctrl+z
sleep 1
shot t25-inspector-undo
# Redo through the Edit menu: GTK consumes Ctrl+Y inside the focused native
# text control on this build, so the menu is the reliable redo path.
click 48 12
click 80 66
sleep 1
shot t25-inspector-redo

# --- T2.2/T2.5: palette strip and placement --------------------------------
# Palette order: Panel, Group, Label, Button ... at client x 82 + 44*n.
click 214 76
shot t25-palette-armed
# Drag-place a Button on empty canvas.
xdotool mousemove --window "$win" 600 430 mousedown 1
sleep 0.3
xdotool mousemove --sync --window "$win" 700 480
sleep 1
shot t25-placing-button
xdotool mouseup 1
sleep 1
shot t25-placed-button

# --- T2.3/T2.5: Events tab and handler stub --------------------------------
click 1086 157
shot t25-events
# The placed button declares `click`; opening it appends an ABI v2 handler
# stub and switches the centre notebook to Code.
click 1050 236
sleep 1
shot t25-handler-opened

# --- T2.3/T2.5: edit a text property --------------------------------------
xdotool key ctrl+1
sleep 1
click 1009 157
sleep 0.5
click 622 248
dblclick 1119 343
xdotool key ctrl+a
type_text "Hello T2.5"
xdotool key Return
sleep 1
shot t25-inspector-text-edit

# --- T2.4/T2.5: generated source, module switch ----------------------------
click 370 147
sleep 1
shot t25-source
xdotool mousemove --window "$win" 500 300 click 1
xdotool key ctrl+End
sleep 1
shot t25-source-end
click 30 239
sleep 1
shot t25-module-notes
click 30 212
sleep 1

# --- T2.5: menus, shortcuts and tooltips -----------------------------------
click 22 12
shot t25-file-menu
xdotool key Escape
sleep 0.5
click 155 12
shot t25-help-menu
xdotool key Down Return
sleep 1
shot t25-help-dialog
xdotool key Escape
sleep 0.5
# Hover a palette button long enough for GTK's tooltip.
xdotool mousemove --window "$win" 126 76
sleep 2.5
shot t25-tooltip

# Optional end-to-end persistence check: save the edited project. Run with a
# throwaway CAMPY_PROJECT so the demo fixture stays clean:
#   CAMPY_PROJECT=/tmp/opencode/g2-demo CAMPY_PROBE_SAVE=1 scripts/ui_probe.sh xvfb
if [ "${CAMPY_PROBE_SAVE:-0}" = "1" ]; then
  click 54 47
  sleep 1
  shot t25-saved
fi
