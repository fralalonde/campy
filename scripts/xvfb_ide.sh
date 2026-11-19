#!/usr/bin/env bash
# Run the Campy IDE under Xvfb + openbox for scripted X11 automation
# (xdotool real-event injection, ImageMagick capture). Launch each piece as
# a persistent background task; the display stack must outlive short-lived
# commands or the window manager gets reaped and GTK frames stop mapping.
#
#   Xvfb :99 -screen 0 1600x1000x24 &      # background
#   DISPLAY=:99 openbox &                 # background (GTK frames need a WM)
#   CAMPY_PROJECT=examples/demo scripts/xvfb_ide.sh
#
# Screenshots: DISPLAY=:99 import -window root out.png
# Drive:      DISPLAY=:99 xdotool key ctrl+2   (XTEST; --window key sends are ignored)
# Instrument: CAMPY_DUMP=1 prints every widget's live geometry + canvas paints.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/gleam/apps/campy_ide_wx"
export DISPLAY="${DISPLAY:-:99}"
export GDK_BACKEND=x11
export CAMPY_PROJECT="${CAMPY_PROJECT:-$ROOT/examples/demo}"
export CAMPY_DUMP="${CAMPY_DUMP:-0}"
exec gleam run
