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
shot() { import -window root "$OUT/$1.png"; echo "shot=$OUT/$1.png"; }
click() { xdotool mousemove --window "$win" "$1" "$2" click 1; sleep 1; }

shot initial
click 263 107
click 400 300
shot empty-click
click 300 140
shot selected-label
click 300 166
shot selected-text
xwininfo -root -tree > "$OUT/windows.txt" 2>&1 || true
# resize via the south-east handle (+40, +12)
xdotool mousemove --window "$win" 820 176 mousedown 1
xdotool mousemove_relative --sync 40 12
xdotool mouseup 1
sleep 1
shot resized-text
# move via the grip (+30, +30)
xdotool mousemove --window "$win" 240 160 mousedown 1
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
# select the moved text field, then Ctrl-click the label: multi-selection
click 500 200
xdotool windowfocus --sync "$win" 2>/dev/null || true
xdotool keydown ctrl
xdotool mousemove --window "$win" 400 133 click 1
xdotool keyup ctrl
sleep 1
shot multi-select
# drag the group grip (+20, +20)
xdotool mousemove --window "$win" 240 136 mousedown 1
xdotool mousemove_relative --sync 20 20
xdotool mouseup 1
sleep 1
shot moved-group
# marquee: drag on empty canvas across both controls
xdotool mousemove --window "$win" 500 250 mousedown 1
xdotool mousemove --window "$win" 240 130
sleep 1
shot marquee
xdotool mouseup 1
sleep 1
shot marquee-result

# --- T2.2: palette, placement, adoption, clipboard, reparent --------------
# Palette rows (window coordinates): Panel 342, Group 372, Label 402,
# Button 432, Text 462, Memo 492. Toolbar row: y 72.
click 100 342
shot palette-armed-panel
# Drag a panel onto empty canvas: (650,320) -> (800,410).
xdotool mousemove --window "$win" 650 320 mousedown 1
xdotool mousemove --window "$win" 800 410
sleep 1
shot placing-panel
xdotool mouseup 1
sleep 1
shot placed-panel
# Arm Button and click inside the new panel: it must adopt the control.
click 100 432
click 700 365
shot placed-button-in-panel
# Copy the selected button, then paste it as a sibling.
click 370 72
click 444 72
shot pasted-button
# Duplicate and delete, then undo the delete.
click 524 72
shot duplicated-button
click 605 72
shot deleted-button
click 123 72
shot undo-delete
# Move the original button out of the panel back to the root by its grip.
click 700 365
xdotool mousemove --window "$win" 720 375 mousedown 1
xdotool mousemove --window "$win" 520 350
sleep 1
shot moving-out-of-panel
xdotool mouseup 1
sleep 1
shot moved-out-of-panel
# Ctrl-click a native widget (button) while the panel is selected. This is the
# path that used to ignore the modifier because the click did not fall through
# to the canvas.
click 670 400
shot selected-panel-again
xdotool keydown ctrl
xdotool mousemove --window "$win" 520 350 click 1
xdotool keyup ctrl
sleep 1
shot ctrl-widget-select
# Move the button back into the panel. The diff inserts into panel_1 before
# removing the root-level button; removals must be applied first or the old
# widget is destroyed under the new id.
click 520 350
xdotool mousemove 942 512 mousedown 1
xdotool mousemove 1140 525
sleep 1
shot reparent-into-earlier-sibling
xdotool mouseup 1
sleep 1
shot reparented-into-earlier-sibling
# It must still be selectable (not a ghost).
xdotool mousemove 1130 527 click 1
sleep 1
shot reparented-widget-alive

# --- T2.3: inspector edits and events --------------------------------------
# The inspector packs two field/value pairs per row. Client coordinates below
# are calibrated from reparented-widget-alive.png (window client origin adds
# ~164 px vertically to the root screenshot):
#   row 2 = parent | x   row 3 = y | w   row 4 = h | text
#   value columns are 1 and 3; the events list starts at x ~784.
# The selected control is button_1 (parent panel_1) and declares click.
shot t23-inspector-single
# Edit x (row 2, right-hand value column) to 500.
xdotool mousemove --window "$win" 609 592 click --repeat 2 --delay 80 1
sleep 0.5
xdotool key ctrl+a
xdotool type --delay 30 "500"
xdotool key Return
sleep 1
shot t23-inspector-x-edited
# Edit text (row 4, right-hand value column).
xdotool mousemove --window "$win" 609 640 click --repeat 2 --delay 80 1
sleep 0.5
xdotool key ctrl+a
xdotool type --delay 30 "Hello T2.3"
xdotool key Return
sleep 1
shot t23-inspector-text-edited
# Click the declared click event: the missing handler is appended as an ABI v2
# stub and the Code page opens.
xdotool mousemove --window "$win" 784 569 click 1
sleep 1
shot t23-handler-opened
# The stub is appended at the end; scroll the code editor to prove the ABI v2
# shape (the opened page starts at the top of handlers.gleam).
xdotool mousemove --window "$win" 900 250 click 1
xdotool key ctrl+End
sleep 1
shot t23-handler-stub
