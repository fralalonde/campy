# Campy

Campy is a native, Gleam-first RAD IDE (an IDDDE — integrated develop, deploy,
debug environment) for the BEAM. Design a form, edit handlers, run the app as a
supervised OTP application, and deploy it to peer nodes. The UI is wxWidgets,
driven from the BEAM: no Rust, no NIF.

## Requirements

- Gleam 1.16+ and Erlang/OTP 27+ with the `wx` application (wxWidgets 3.2 and
  GTK3 on Linux).
- Python 3, `just`, and a display for the IDE. Headless tests need no display.
- Linux: Wayland or X11 with the wxWidgets runtime libraries. On this machine,
  run inside the Fedora `dev-raw` toolbox.

## Run

```sh
just doctor
just run
```

`just run` opens the IDE shell on `examples/demo`. Point `CAMPY_PROJECT` at a
project directory to open another project.

## Current state (Phase 2)

- **View layer** (`campy_view`): a declarative node tree, values, patches,
  structural diff, and canonical JSON documents. 71 tests.
- **wx renderer** (`campy_wx`): widget table, sizer/free layout, patch
  application that leaves unchanged values alone, event normalization, and
  shell chrome (menus, toolbar, status, notebook, tree, grid, Scintilla,
  dialogs). The design and live modes share one renderer.
- **Project format** (`campy_project`): a project is a directory with canonical
  `campy.json`, `modules/<slug>/form.json`, and `handlers.gleam`; unknown fields
  survive a round trip.
- **Widget catalog** (`campy_catalog`): the target-neutral widget table (kinds,
  labels, events, default geometry and properties).
- **Designer** (`campy_design`): absolute geometry, hit-testing, resize/move,
  structural edits, drop adoption, and reparenting.
- **IDE model** (`campy_ide_model`): tabs, active module, selection, console,
  undo/redo, palette placement, clipboard, duplicate/delete, z-order, inspector
  geometry/text edits, and ABI v2 handler stubs.
- **IDE shell** (`gleam/apps/campy_ide_wx`): module tree, widget palette, form
  canvas with selection chrome, Scintilla code view, console, an editable
  inspector with typed geometry cells, an events list that opens or creates
  handler source, save, undo/redo.
- **Sample project**: `examples/demo`.

Not built yet: generated source tab, form preview in the IDE, Run/hot update,
the ABI v2 runtime, and peer-node deploy. See
[`docs/PHASE2.md`](docs/PHASE2.md).

## Development

```sh
just check   # formatting + every package's tests, headless
just test
just fmt
just clean
```

Headless X11 probe (Xvfb + xdotool + ImageMagick + openbox) captures the IDE
and drives clicks/drags; screenshots land in `generated/ui/`:

```sh
scripts/ui_probe.sh xvfb
```

Renderer harness (needs a display):

```sh
cd gleam/packages/campy_wx
gleam run -m campy_wx/gallery
CAMPY_WX_SMOKE=1 gleam run -m campy_wx/shell_demo
```

## Design notes

- [ADR 0003](docs/adr/0003-wx-ui-toolkit.md): wxWidgets replaces Slint; no UI NIF.
- [ADR 0004](docs/adr/0004-view-tree-and-projection.md): view tree, patches,
  projection, ABI v2, local peer nodes.
- [ADR 0005](docs/adr/0005-source-format.md): canonical JSON source, binary
  artifacts, project = directory.
- [`docs/PHASE2.md`](docs/PHASE2.md): the current task plan.

`docs/ARCHITECTURE.md`, `docs/MVP.md`, and `docs/PHASE1.md` are historical
records of the Phase 1 Slint prototype.
