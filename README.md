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
  structural diff, and canonical JSON documents. 73 tests.
- **wx renderer** (`campy_wx`): widget table, sizer/free layout, patch
  application that leaves unchanged values alone, event normalization, and
  shell chrome (menus, toolbar, status, notebook, tree, grid, Scintilla,
  dialogs). The design and live modes share one renderer.
- **Project format** (`campy_project`): a project is a directory with canonical
  `campy.json`, `modules/<slug>/form.json`, and `handlers.gleam`; unknown fields
  survive a round trip.
- **Widget catalog** (`campy_catalog`): the target-neutral widget table (kinds,
  labels, events, default geometry and properties).
- **Generated source** (`campy_source`): deterministic, read-only Gleam source
  that builds the form's `campy_view.Node` tree through the public DSL. It is a
  target-neutral projection of `form.json` (not a second source format, not
  direct wx calls) and doubles as the export path.
- **Designer** (`campy_design`): absolute geometry, hit-testing, resize/move,
  structural edits, drop adoption, and reparenting.
- **App runtime** (`campy_app`): the ABI v2 actor — state, `view`, dispatch by
  handler name, contained handler errors, `Log`/`Notify`/`Stop` effects,
  generation-stamped views, `state_version`, and `migrate`.
- **App generator** (`campy_appgen`): emits the per-form dispatch module
  (`campy_app_<slug>`) with the designed form embedded as `view/1` and the
  user's handlers verbatim.
- **Peers** (`campy_peer`): local BEAM nodes via OTP's `peer` module —
  boot, health round trips, calls over distribution, teardown, and runtime
  distribution for the IDE node.
- **Runner** (`campy_runner`): the control surface on a peer node — install
  compiled beams, start/stop app actors, status; the IDE drives it over
  Erlang distribution and receives reports on its own subjects.
- **Node manager** (in `campy_ide_wx`): the Nodes page — start/stop peer
  nodes, deploy the active form to one, hot-redeploy (upgrade) remotely, and
  watch the peer's reports in the same console.
- **Run** (in `campy_ide_wx`): deploys the active form in-VM — scratch
  package, `gleam build`, code load — and starts the ABI v2 actor; a live
  **Run** page grafts the published view, canvas events route to the actor,
  and reports land in the console. Saving while running hot-updates the code
  (pause → `code:load_binary` → resume → `Upgrade` → `migrate/2`).
- **IDE model** (`campy_ide_model`): tabs, active module, selection, console,
  undo/redo, palette placement, clipboard, duplicate/delete, z-order, inspector
  geometry/text edits, ABI v2 handler stubs, and Form/Code/Source page state.
- **IDE shell** (`gleam/apps/campy_ide_wx`): reference-style workspace with
  File/Edit/View/Help menus, a text-only action toolbar over a 16-button
  palette strip, a Projects/Modules navigator, a centre Form/Code/Source
  notebook with a bottom console, and a 330 px Properties/Events inspector
  dock. The property grid is one field per row; events open or create ABI v2
  handler stubs. Selection uses thin blue outlines, small resize handles and a
  grip, and a control can be moved by dragging its body. Save, undo/redo,
  clipboard, duplicate/delete and page switching have menu/toolbar actions and
  frame accelerators; Help lists the shortcuts. Text-editing shortcuts stay
  with the focused editor on Code/Source.
- **Sample project**: `examples/demo`. 250 tests green.

Not built yet: live app preview in the IDE, Run/hot update, the ABI v2
runtime, and peer-node deploy. Gate G2 (design the demo from scratch, save,
reopen, and diff the canonical JSON; Run belongs to M3) is next; see
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
