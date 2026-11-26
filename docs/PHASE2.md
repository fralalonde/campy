# Phase 2 — zgui migration (Slint leaves the tree)

This is a dispatch plan in the `docs/PHASE1.md` format: every task is a
self-contained brief executable by a fresh agent given only §1 (Shared
context) and the brief. Review is batched at gates (§6). The phase branch
is **`zgui-migration`** (forked from `archive/slint-ui`); task branches are
`z2/<task-id>`.

Goal, one sentence: **campy's native engine is zgui driven by bridge
protocol v2 — the IDE shell, the designer, and the editor/console are all
`ControlDesc` documents — and campy can open its own source tree as a
project.**

ADR: `docs/adr/0003-zgui-migration.md` (read it first).

## Status

- **Z0.2 done** (see the brief's verified facts below).
- **Z3.1 core done**: `code_editor`/`memo` render zgui-editor with the
  Gleam tree-sitter grammar; `SetCode`/`ReadText(source)`/
  `editor:<id>:changed` wired and integration-tested. Remaining from the
  Z3.1 brief: `SetMarks` (diagnostics layers), read-only, debounce, and
  the Resize/close-reaping polish.
- **Z3.2 core done**: `console` renders zgui-terminal over `Channels`;
  `AppendConsole` feeds it, keyboard flows back as
  `console:<id>:input`; integration-tested. Remaining: resize
  propagation.
- **Z2.2 merged** (shell emitter + ops layer, 21 shell tests). Its
  review closed the keyboard gap in the renderer: modified/special keys
  cross as `key` events (`ctrl+s`, `f6`, `delete`); plain typing stays
  with the focused editor. Menu items/nav/tabs ride `model` +
  `selected` payloads (no per-item controls); structural edits and
  theme/title changes are `Reload`s (accepted mapping, see the Z2.2
  report notes for G1).
- **Wave 1 merged**: Z1.1 (CCL v2), Z1.2 (codec v12), Z1.3 (dogfood
  builder, `just dogfood` green and idempotent; a stale pre-v12
  `projects/workspace.campy` is backed up to `.bak` and replaced —
  same rule the IDE gets in Z2.3). G0 passed.
- **erl_eval trap for eval-based scripts** (found the hard way in
  Z1.3's review): two top-level `case` clauses binding the same variable
  name in ONE `-eval` sequence trip `unsafe_var` at boot — give each
  case distinct variable names.
- Not started: Z2.* (the IDE emitters and loop), Z3.3 (LS↔editor),
  Z4.* (smoke suite port, packaging, docs).

Dispatch per §1.6 on `opencode-go/deepseek-v4.1-flash` subagents (one
brief per session); the coordinator (GLM-5.3) owns the renderer between
waves.

### Form editor event model (as built, keep this true)

While a form is rendered in the Form Editor, the components inside the
`surface` are **passive**: each shows its property values (or values derived
from related components) and nothing else. The Form Editor handles every
event — clicks, drags, keystrokes.

| kind | in the Form Editor | in a preview window |
|---|---|---|
| `button`, `menu`, `combo`, `list` rows | drawn; no handler, no tab stop | live |
| `edit` | shown; read-only, cannot focus | editable |
| `checkbox`, `radio` | `☑`/`☐` glyph drawn from `checked` | widget |
| `memo`, `code_editor`, `console` | static text of the contents | live |
| `slider` | inert `Progress` at `value` | draggable |

- Passivity rides `FlatControl.passive`, carried down from any `surface`
  ancestor, so a control nested in a panel inside the canvas is passive too.
- Every passive wrapper carries `campy-passive` (`pointer-events: none`):
  nothing inside it can focus itself or claim a press.
- The canvas listens for `pointerdown/move/up/wheel` in the **capture** phase,
  so it hears every press inside the form whatever is under the pointer.
- The canvas owns hovering in the designer: `pointer:canvas:move` hit-tests the
  form and puts the component's `hint` on the status line. Per-control
  `pointer enter/leave` remains for the live shell.
- Wire coordinates are **whole window CSS pixels**: `x;y;button;mods`. The
  renderer rounds, because `float.parse` in the BEAM rejects `376` (an Erlang
  float needs its point) and an unparseable coordinate reads as zero. The BEAM
  maps to form-local with `shell.layout(w,h).canvas_x/y` and the module
  window's position.
- A preview window loads the same document **without a `surface`**, so nothing
  in it is passive; passivity is a property of the designer, not of the form.

Diagnostics (no desktop injection needed):
`CAMPY_UI_CLICK=x,y`, `CAMPY_UI_DRAG=x1,y1,x2,y2` and `CAMPY_UI_MODS=ctrl`
hand the real window one platform pointer gesture after its first frame — the
same `SurfaceEvent`s the winit backend sends, through the window's own input
path. `CAMPY_UI_DRAG_STEPS`/`CAMPY_UI_DRAG_INTERVAL_MS` pace that drag like a
hand (`CAMPY_UI_DRAG_TICK=1` also asks for a frame each step).
`CAMPY_POINTER_LOG=1` prints what the canvas heard and
`CAMPY_UI_FRAME_LOG=1` prints frames, their gaps, what a present costs and the
pacing a window chose. `ZGUI_LATENCY=/path.jsonl` writes the framework's
per-stage frame trace (`f.layout`, `acq.in/out`, `p.draw`, …).

### Form editor polish (gestures, inspector, apps)

- **One undo step per gesture.** A drag or resize changes the document under
  the pointer but records nothing until the button is released; the step is
  the document as the press found it. Escape mid-gesture puts it back (a
  cancel, not a commit).
- **The selection moves as a block.** The delta is clamped by the selection's
  own outline, so the first component to reach an edge stops them all instead
  of the block tearing apart; the outline is also the grab area, so pressing
  the gap between two selected components drags the block.
- **The marquee shows its contents while it grows.** A transparent band (no
  fill) plus live outlines and handles for the components it would take; the
  real selection is unchanged until release (`State.preview_selection`).
- **Parents are a first-class notion.** A drag shows where it will land: a
  dashed outline around the container under the pointer (the window when it is
  over none). The hierarchy changes on release — the container under the
  pointer adopts the selection, or the window does — as one undo step, not
  mid-drag. The inspector's **Parent** row names the current parent and
  reparents without a drag, offering the window and every container outside
  the component's own subtree.
- **Moving the module window** takes its delta in canvas coordinates. Form
  coordinates move with the window being dragged, so a delta taken in them
  chases its own output — the jitter the drag had.
- **Popups** read the live geometry signals when they open (a resize or a move
  changes those, not the loaded document), and closing keeps the card mounted
  but hidden so its area is repainted instead of left as an empty box.
- **The inspector keeps its tab** when the selection changes; **double-clicking**
  a component opens its default handler (`clicked`/`toggled`/`edited`/… by
  kind) in the code pane without switching the inspector to Events.
- **The Form/Raw tabs are gone**: there is no generated form source to show,
  only the form and the handler code (`Ctrl+Tab` still toggles those).
- **Apps run from the navigator rows.** Each module row carries a run button
  at its right end (green ▶ to start, red ■ to stop, both drawn from a fixed
  slot pool so the document's shape does not change with the number of rows);
  a project row carries one too when the project names an app — its
  `default module`, chosen in the project inspector. Running a project's app
  switches to that project first. Several can run at once, each in its own
  window; a project with no default module is not runnable as a project.
- Codec v13 adds `Project.default_module`. A v12 file (checked in as
  `gleam/packages/campy_form/test/fixtures/project-v12.campy`) is read as v13
  with no default module, so a user's workspace survives the upgrade; older
  versions are still rejected.
- The in-app file browser filters by what the dialog is for (project files,
  images), so the Open dialog cannot offer files the codec will refuse.

### Presentation is a first-class part of drag feel

A drag must show a new position on the frame after the move, so what a present
costs *is* what a drag feels like. Measured on a 1280×860 window at scale 1.4
(1792×1204 device px), dragging a component with a paced pointer:

| path | work per move | present wait | drag |
|---|---|---|---|
| `PresentPacing::Display` (wgpu `Fifo`) | BEAM 1.0–1.5 ms, frame ≤0.3 ms | 22–50 ms in `get_current_texture` | 120 steps at 8 ms took 4.8 s |
| `PresentPacing::Platform` (`Mailbox`) | same | ~0 ms | the same 120 steps took 0.96 s |

The wait is on the UI thread, which is also the thread that reads pointer
events and runs the command drain, so a blocked present is a blocked drag. A
window that is idle draws nothing on either path. Since Campy animates nothing
that needs the display's cadence, `campy-renderer/src/graphics.rs` installs a
factory that chooses `Platform` on a Wayland surface (and for any surface that
paces itself), `Display` elsewhere; `CAMPY_UI_PACING=display|platform` is the
A/B override. A gesture's whole diff crosses the bridge as one `Op::Batch`, so
one pointer move is one wake and one frame rather than one per changed field.

## 1. Shared context (paste this section into every dispatch prompt)

### 1.1 What Campy is (zgui-migration state)

Campy is a Gleam-first RAD studio: BEAM + a Rust NIF (`campy-bridge`,
`campy-renderer`) owning the native UI. On this branch the renderer is
**zgui** (git-pinned), replacing the Slint interpreter. Key facts:

- The IDE is a Gleam application using the same runtime it designs for.
- The NIF owns one OS UI thread: one winit event loop
  (`with_any_thread(true)` driving zgui's public `WinitApp` — no zgui
  fork), one zgui `Runtime`, one window per bridge session (IDE shell,
  preview windows).
- Commands cross through a bounded queue drained by a `set_interval`
  timer inside the app; completions/errors arrive as mailbox events
  (`campy_bridge_ffi:poll` — **never add a second poller in one VM**).
- UI-as-data: `LoadUi` carries a **control-description tree**; the host
  turns it into a zgui document and re-builds incrementally on change.
  Granular ops address controls by integer id. There is **no interpreter
  and no per-load compile**; F6 reload = BEAM regenerates the description
  and re-`LoadUi`s.
- Handlers are zero-arg Gleam functions derived from
  `(control_name, event_key)` — unchanged from before.
- The designer model is renderer-agnostic: `campy_form.container_at*`
  hit-tests from the form model; the Rust `surface` control kind forwards
  raw pointer phases (`pointer:<id>:<phase>` with `"x;y"` payloads) and
  the BEAM drives drag/resize previews with `SetGeometry`.

### 1.2 zgui facts agents may rely on (verified against the pinned rev)

- `zgui::prelude::*` gives `app()`, `RwSignal`, `use_windows()`,
  `use_window()`, the `view!` macro, and `css!`.
- Elements: `column/row/box/text/label/field/control/editor/image/scroll/
  spacer/stack`. Components in `zgui_ui::prelude`: `Button`, `Input`,
  `Checkbox`, `Combobox`, `Select`, `Slider`, `Progress`, `Menu`,
  `Menubar`, `VirtualList`, `Card`, `Dialog`, `Tabs`…
- Signals are created in the window's reactive scope during view build;
  writing them from the host thread between frames is the sanctioned
  bridge pattern (settle/flush happens in the next frame).
- `zgui_view::time::set_interval(every, cb)` is the drain-timer API.
- Styling is CSS through one application sheet; themes are root classes
  (`.campy-dark` / `.campy-light`) that flip custom properties
  (`--campy-accent`, `--campy-bg`, …). Custom properties cascade and are
  the mechanism for themed control colors.
- The Gleam side NEVER sees Rust types: everything crosses as the wire
  protocol below.

### 1.3 Codebase map

| Path | What it is |
| --- | --- |
| `rust/crates/campy-bridge` | Rustler NIF: sessions, command decode, event encode. Rust. |
| `rust/crates/campy-renderer` | zgui host: UI thread, windows, control builders, editor/console kinds. Rust. |
| `gleam/packages/campy_bridge` | Gleam externals: `Command`, `ControlDesc`, `WireValue`, `poll`. |
| `gleam/packages/campy_ccl` | CCL palette catalog — **aligned to the zgui widget model in Z1.1**. |
| `gleam/packages/campy_form` | Form model, hit-testing, project codec — **codec v12 in Z1.2**. |
| `gleam/packages/campy_app`, `campy_broker`, `campy_runner` | P1 packages; consume protocol v2 (Z2.x). |
| `gleam/apps/campy_ide` | The IDE: loop, state, shell emitter, preview, smoke helpers. |
| `scripts/workspace.py`, `justfile` | Build orchestration (`PACKAGES` tuple must list every package). |
| `docs/PHASE1.md` | The prior phase (broker/runner) — still the lore for the build-port pattern (`campy_hot_ffi.erl`). |

### 1.4 Wire protocol v2 (authoritative; keep in sync on both sides)

Gleam side (`gleam/packages/campy_bridge/src/campy_bridge.gleam`);
Rust mirror (`rust/crates/campy-renderer/src/wire.rs` + NIF decode in
`campy-bridge`). Variant names are the wire terms (rustler tagged enums).

```gleam
pub type WireValue {
  WireText(String)
  WireBool(Bool)
  WireInt(Int)
  WireFloat(Float)
  WireList(List(WireValue))
  WireStruct(List(#(String, WireValue)))
  WireImage(String)   // file path
}

pub type ControlDesc {
  ControlDesc(
    id: Int,            // stable, from the form model (or shell section ids)
    kind: String,       // CCL kind key, see table
    text: String,       // primary caption / value / title
    x: Int, y: Int, w: Int, h: Int,   // device-independent px
    enabled: Bool,
    visible: Bool,
    props: List(#(String, WireValue)),
    children: List(ControlDesc),
  )
}

pub type Command {
  LoadUi(generation: Int, title: String, width: Int, height: Int,
         theme: String,                    // "light" | "dark"
         controls: List(ControlDesc))
  SetText(generation: Int, control: Int, value: String)
  SetBool(generation: Int, control: Int, key: String, value: Bool)
  SetInt(generation: Int, control: Int, key: String, value: Int)
  SetFloat(generation: Int, control: Int, key: String, value: Float)
  SetModel(generation: Int, control: Int, items: List(WireValue))
  SetGeometry(generation: Int, control: Int, x: Int, y: Int, w: Int, h: Int)
  SetCode(generation: Int, control: Int, source: String)
  AppendConsole(generation: Int, control: Int, bytes: String)  // UTF-8 chunk
  SetMarks(generation: Int, control: Int, layer: String, items: List(#(Int, Int, String)))
  ReadText(generation: Int, control: Int, key: String)
  Resize(generation: Int, width: Int, height: Int)
}
```

Event envelope is unchanged:

```gleam
pub type NativeEvent { NativeEvent(session: Int, generation: Int, kind: String, payload: String) }
```

Kinds (strings; the IDE loop parses them):

| kind | payload | source |
| --- | --- | --- |
| `ui-loaded` | thread detail | after LoadUi applies |
| `closed`, `command-failed`, `runtime-failed` | reason | session lifecycle |
| `control:<id>:clicked` | `""` | button, menu item, surface tiles |
| `control:<id>:toggled` | `"true"/"false"` | checkbox/radio |
| `control:<id>:accepted` | current text | edit |
| `control:<id>:edited` | current text | edit, memo, code_editor |
| `control:<id>:selected` | selected item text | combo, list, menu |
| `control:<id>:changed` | value as string | slider, progress |
| `pointer:<id>:down/move/up` | `"x;y"` local to the surface | surface kind |
| `pointer:<id>:wheel` | `"dx;dy"` | surface kind |
| `editor:<id>:changed` | full source, debounced | code_editor |
| `console:<id>:input` | line typed (no newline) | console kind |
| `read:<id>:<key>` | value | reply to ReadText |
| `lsp:diagnostics`, `lsp:completions` | as today | Gleam LS client |

Control kinds (CCL keys) and their Rust mapping:

| kind | zgui rendering | notable props |
| --- | --- | --- |
| `label` | `text` | — |
| `edit` | `Input` | `placeholder`, `read-only` |
| `memo` | `editor` element | `read-only` |
| `button` | `Button` | `variant` ("solid"/"outline") |
| `menu` | `Button` + `Menu` popup | `model` (item list) |
| `checkbox` | `Checkbox` | `checked` |
| `radio` | `Checkbox` (radio role) | `checked`, `group` |
| `combo` | `Combobox` | `model`, `current-index` |
| `list` | `VirtualList` rows of `label` | `model` |
| `slider` | `Slider` | `minimum`, `maximum`, `value` |
| `progress` | `Progress` | `value`, `maximum` |
| `picture` | `image` | `source`, `fit` |
| `panel`, `group` | `box` containers | `layout` ("free"/"column"/"row"), `border` |
| `code_editor` | zgui-editor `Editor` | `language`, `read-only`, `line-numbers` |
| `console` | zgui-terminal `Terminal` | — |
| `surface` | campy custom designer surface | children at geometry |

Geometry: Free layout positions children absolutely (CSS
`position:absolute; left/top/width/height` driven by per-control
signals); Column/Row wrap children in `column`/`row` boxes.

### 1.5 Conventions and guardrails

1. Gleam packages follow the existing layout/registration rules (see
   `PHASE1.md` §1.4 — packages go in `gleam/packages/<name>` and are
   registered in `scripts/workspace.py` `PACKAGES`).
2. **Transition-window acceptance** (until Z2.3 lands): the full-tree
   `just check` is temporarily red because the IDE still speaks protocol v1
   against the v2 NIF. Your brief is done when **your package and every
   package it depends on or breaks** passes its own build and tests:
   `cd gleam/packages/<pkg> && gleam build && gleam test`. Rust must stay
   `cargo check` green (`cd rust && cargo check`). Do not "fix" unrelated
   packages; do not touch `campy_ide`, `campy_app`, or the Rust tree
   outside your brief.
3. Run `just fmt` before finishing (or `cd gleam/packages/<pkg> && gleam
   format` for scoped work). Session-dependent tests skip unless
   `DISPLAY`/`WAYLAND_DISPLAY` is set — keep that convention.
4. Stay inside your brief's Files list. Ambiguity → stop and report.
5. Each task runs in its own worktree: `git worktree add -b z2/<task-id>
   ../campy-wt-<id>` created from `zgui-migration`, commit there, and
   report the commit hash. The coordinator merges.
6. Rust-side work beyond your brief's Files list is out of bounds (the
   coordinator owns the renderer between waves).
7. **Control rendering rule (from Z0.2):** campy's interactive controls
   render as campy-styled base elements (`control`, `field`), which are the
   path verified end-to-end through real surface input. zgui-ui components
   (`Button`, `Input`, `Checkbox`, …) are NOT wired in the renderer yet;
   they get their live-window A/B in Z2.2 — write Gleam-side emitters
   against the CCL kind table only, never against zgui-ui names.

### 1.6 Dispatch template

> You are implementing task `<ID> — <title>` for the Campy repository.
> Work in worktree branch `z2/<task-id>` created from `zgui-migration`
> (see §1.5). Read `docs/PHASE2.md` §1 (Shared context) and your brief
> section only. Follow the brief exactly, including its Files and
> Do-not lists. Run `just fmt` and `just check` before finishing.
> Report: files changed, tests added, `just check` result, the commit
> hash, and any deviations.

## 2. Wave 0 — foundation (coordinator-owned, not dispatched)

### Z0.2 — `campy-bridge`/`campy-renderer`: protocol v2 host

**Done** (commit "Z0.2: protocol v2 host"). Verified facts future briefs
may rely on:

- The zgui stack is pinned to one git source (Cargo.lock carries
  `ee29c7dc`); zgui-editor and zgui-terminal compile against it.
- `with_any_thread` needs no zgui fork: the UI thread builds its own
  winit loop and drives the public `WinitApp`.
- The headless `ui-testing` driver works: scripted surface events with
  **monotonic timestamps** (a stale `Timestamp::ORIGIN` silently breaks
  click synthesis), a null renderer, and `test_pump`/`test_pointer`/
  `test_resize` NIFs. One runtime per process — smoke scenarios run
  sequentially.
- `LoadUi` applies through the per-session document signal (zgui
  rebuilds the document incrementally); granular ops hit the per-control
  signal registry; events flow as §1.4 specifies (envelope unchanged).
- Interactive controls are campy-styled **base elements** (see §1.5.7).
  `code_editor`/`memo` render a zgui-editor `Editor` (set-text and
  changed-events wired; marks/registry are Z3.1), `console` is a styled
  text box until Z3.2, `surface` forwards pointer phases with window CSS
  coordinates. `Resize` and window close-reaping land with Z3.1.

## 3. Wave 1 — pure Gleam, parallelizable after Z0.2 lands

### Z1.1 — `campy_ccl`: align to the zgui widget model

- Depends: Z0.2 · Parallel with: Z1.2, Z1.3 · Size: M · Risk: low ·
  Branch: `z2/z1.1-ccl`

**Goal.** The palette catalog speaks protocol-v2 kinds and props.

**Spec.** Rewrite `campy_ccl.gleam`'s `all()` to the §1.4 kind table:
one entry per row (including new `code_editor` and `console`, both
Common, default sizes 400×300 and 480×240), with each kind's `properties`
keys and `events` keys matching the table's "notable props" plus the
CCL-universal keys every interactive control keeps: `text`, and
events per kind (`clicked`, `toggled`, `accepted`, `edited`, `selected`,
`changed`). `picture` keeps `source` + `transparency`; `panel`/`group`
keep `accepts_children`, `layout`, `border`. Drop Slint-isms
(`placeholder-text` → `placeholder`). Module doc comment states the
zgui mapping per kind (one line each). Update every consumer of removed
keys (grep `campy_ccl` across `gleam/`): `campy_form` validation,
`campy_appgen` event derivation, inspector choice lists — behavior
preserved, only keys renamed per the table. Tests: catalog integrity
(unique keys/ids, per-kind required events present, `code_editor` and
`console` present).

**Files.** `gleam/packages/campy_ccl/**`, plus call-site key renames
where the grep leads (report each).

**Do not.** Touch the bridge, renderer, or project codec. Add
`surface` to the palette (it is IDE-internal).

### Z1.2 — project codec v12: external-source modules, no compat chain

- Depends: Z0.2 · Parallel with: Z1.1, Z1.3 · Size: M · Risk: medium ·
  Branch: `z2/z1.2-codec-v12`

**Goal.** A module can point at a `.gleam` file on disk instead of
embedding its source — the dogfood door — with the codec reset to v12
(no upgrade chain).

**Spec.** In `campy_form/project.gleam`: `Module` gains
`source_origin`: `Embedded(String)` | `External(path: String)`.
Embedded unchanged (verbatim source in the term file); External stores
only the path (relative to the project file, absolute allowed). Saving
is lossless for both; loading External does **not** read the file (the
IDE reads it on open via existing FS FFI — pure codec here). Bump the
public `version` constant to 12; **delete** the v1..v11 upgrade chain,
fixtures, and their tests (no compatibility: only `campy.campy`'s Cat
Café demo exists). Add a small helper `to_v12_project(...)` or regenerate
path: a test-time constructor building the current demo (Cat Café) at
v12, and regenerate `campy.campy` from it (the demo constructor already
exists — keep its control set; sources stay embedded for the demo).
Workspace codec v1 unchanged. Adjust `campy_manifest`'s schema constant
reference if it hardcodes 11 (read the constant — it must stay
`campy_form`'s public `version`, never a literal).

**Files.** `gleam/packages/campy_form/**` (project codec + tests),
`campy.campy` regenerated, `gleam/packages/campy_manifest/**` only if
a literal slipped in.

**Do not.** Change `campy_form`'s form model or hit-testing. Keep any
upgrade machinery. Touch the IDE.

### Z1.3 — dogfood: campy's own tree as a project

- Depends: Z1.2 · Size: S · Risk: low · Branch: `z2/z1.3-dogfood`

**Goal.** `just dogfood` writes `projects/campy-dev.campy`: modules
whose sources are campy's own Gleam files, ready to open in the IDE.

**Spec.** New `scripts/make_dogfood.py` (stdlib only, mirroring
`scripts/workspace.py` style): builds the project term via the same
`erl -noshell -eval` pattern used by `build-app`, creating v12 modules —
one per listed source file — each `External(<repo-relative path>)`, with
a small empty form per module (label + button, 240×160, defaults), and
writes `projects/campy-dev.campy` + registers it in
`projects/workspace.campy` (v1 codec; append if missing, idempotent).
The module list: `gleam/apps/campy_ide/src/campy_ide.gleam`,
`gleam/apps/campy_ide/src/campy_ide/state.gleam`,
`gleam/packages/campy_form/src/campy_form.gleam`,
`gleam/packages/campy_bridge/src/campy_bridge.gleam`,
`gleam/packages/campy_ccl/src/campy_ccl.gleam`. `justfile` recipe
`dogfood` runs it. A gleeunit test asserts the codec round-trips the
generated file (read back, one External path matches) — the python
script writes, the test only reads a fixture copy under
`gleam/packages/campy_form/test/`.

**Files.** `scripts/make_dogfood.py`, `justfile`,
`gleam/packages/campy_form/test/dogfood_fixture.campy` (generated,
checked in), the round-trip test file.

**Do not.** Modify the IDE. Make the IDE open it automatically.

## 4. Wave 2 — the IDE on protocol v2 (after Wave 1 merges)

### Z2.1 — `campy_form/live_preview` v2: form → ControlDesc

- Depends: Z1.1, Z1.2, Z0.2 · Size: M · Risk: medium · Branch: `z2/z2.1-preview-v2`

**Goal.** Replace `to_slint`/`snapshot` with a pure
`form -> List(ControlDesc)` emitter (kinds/props per §1.4; geometry per
the form model; layout Free/Column/Row honored; window root becomes the
tree root). `campy_app`/`campy_ide` preview paths consume it. Golden
test: Cat Café form → expected ControlDesc tree (checked-in fixture).

**Additions from Z1.1's review.** The form model grows with this task:
`campy_form.Kind` and `kind_from_key` gain `code_editor` and `console`
(they are palette kinds now), including default geometry/props wiring
and `campy_form`'s own validation adjustments. `preview.gleam` (the
static generated-source view) may be deleted if nothing but tests use
it — check first, report if the IDE still imports it.

**Files.** `gleam/packages/campy_form/**` (form model kinds +
`live_preview.gleam` rewritten, tests + fixture), call-site adaptation in
`gleam/packages/campy_app/**` and the thin `campy_ide/live_preview_ui`
shim (derive → LoadUi).

**Do not.** Keep any Slint emission. Touch the project codec (Z1.2
owns it, and may be merging concurrently — rebase on `zgui-migration`
if it lands first).

### Z2.2 — IDE shell v2: `campy_ide/ide_ui/shell.gleam` becomes a ControlDesc emitter

- Depends: Z2.1, Z1.1 · Size: L · Risk: high (flagged G1) · Branch: `z2/z2.2-shell-v2`

### Z2.2 — IDE shell v2: `campy_ide/ide_ui/shell.gleam` becomes a ControlDesc emitter

- Depends: Z2.1, Z1.1 · Size: L · Risk: high (flagged G1) · Branch: `z2/z2.2-shell-v2`

**Shell wire contract (the section ids the IDE loop routes by; keep
these exact — they are the Rust-side control ids the granular ops
address):**

| id | kind | content / behavior |
| --- | --- | --- |
| `menu-bar` | `panel` (row) | File/Edit/View/Project buttons, each a `menu` control whose `model` is its item list; emits `control:<id>:selected` |
| `palette` | `panel` (row) | one `button` per CCL entry (class `campy-palette-tile`), click → designer placement; hover hint via the status line |
| `view-toggle`, `run`, `stop` | `button` | form/code view switch; Run/Stop |
| `status` | `label` | the status line (SetText) |
| `projects-nav` | `panel` (column) | project entries (`list`-styled rows via `SetModel`) |
| `module-tabs` | `panel` (row) | open modules: tab label + close × per entry (`SetModel`) |
| `canvas` | `surface` | the designer canvas; children = the module's controls at their geometry; raw `pointer:canvas:*` drives select/drag/marquee (Gleam hit-tests); selection rectangle + marquee are extra rects updated by `SetGeometry` |
| `inspector` | `panel` (column) | per-CCL property rows: `edit`/`checkbox`/`combo` per PropType; emits edited/toggled/selected with the row key in the payload convention below |
| `code-view` | `code_editor` | the handler source (SetCode / editor-changed / SetMarks from LS) |
| `console` | `console` | fed by `AppendConsole`; input lines arrive as `console:console:input` |
| `dialogs…` | `panel` (visible=false) | settings + project dialogs, shown by SetBool |

Row-id convention: every interactive element is its own control with a
derived id, so events need no embedded keys — inspector rows are
`insp:<prop-key>`, menu items `menu:<menu>:<item>`, palette tiles
`tile:<kind>`, tabs `tab:<module>`, tab closers `tabx:<module>`. Payloads
stay values only. **Id mapping (from Z2.1): every shell id is a
`campy_form.wire_id(<name>)` integer** (the same 31-bit hash the
designed forms use; 0 = window root) — do NOT invent a fixed id table;
derive all section ids through `campy_form.wire_id` and keep a
name↔id glossary in the emitter's doc comment. Z2.3's loop parses
`control:<wire id>:<event>` exactly like campy_app does
(`find_control_by_wire_id`).

**Goal.** Replace the Slint emitter with the builder above. Every
interaction emits the §1.4 event kinds; the shell consumes scalar/model
diffs via the granular ops (`SetText`/`SetModel` per section id) — the
same data-driven discipline as today, no LoadUi for ordinary edits. The
shell description is loaded once; F6 re-LoadUi's it.

**Note from Z1.1.** `campy_ccl` declares `text` as a universal property
row; the inspector's unknown-key routing (`set_control_prop`) would
shadow the `text` FIELD edit, so the shell's inspector rows must treat
`text` specially (route it to the same editor the field edit uses).

**Files.** `gleam/apps/campy_ide/src/campy_ide/ide_ui.gleam`,
`ide_ui/shell.gleam` (rewritten), `campy_ide_snapshot.gleam` (port the
snapshot harness to v2 ops), tests/fixtures it owns.

**Do not.** Touch `campy_ide.gleam`'s loop (that is Z2.3). Lose any
panel, menu item, or keybinding that exists today. Introduce new
concepts in the UI.

### Z2.3 — IDE loop + state: protocol-v2 routing, designer gestures, preview apply

- Depends: Z2.2 · Size: L · Risk: high (flagged G1) · Branch: `z2/z2.3-loop-v2`

**Goal.** `campy_ide.gleam` speaks v2 end to end: event-kind parsing
(control/pointer/read/console/lsp), designer gesture handling from
`pointer:*` phases (click-select, drag-move with `SetGeometry` previews
committed on release, marquee, right-click context menu, keyboard as
today), inspector edits, Run/F7/Stop through broker+runner (P1 seams,
unchanged), console feeding via `AppendConsole`, editor Apply flow
(`ReadText`/editor-changed → LS → file writes for External modules),
F6 (regenerate shell → LoadUi, BEAM module swap unchanged), snapshot
harness green, smoke helpers updated.

**Notes from the merged waves.**
- **Workspace rejection is expected:** codec v12 has no upgrade chain,
  so a stale `projects/workspace.campy` (or its embedded project
  snapshots) loads with an error — treat that as "start a fresh
  workspace" (log one console line), never a crash.
- **`campy_runner`'s one failing test** (via the `campy_app` protocol
  break) lands in this task's scope to re-green; it should be a small
  fixture/expectation fix once `campy_app` compiles against Z2.1.
- `Module.source` is now `source_origin: SourceOrigin` — the IDE's
  module editor reads `External` paths from disk (existing FS FFI) and
  writes back through the same codec.
- `progress` has no events (display-only); the inspector shows its
  properties but derives no handler stub for it.

**Files.** `gleam/apps/campy_ide/src/**` (loop, state,
`campy_native_smoke*`, `campy_gesture_probe*`), its tests.

**Do not.** Add a second poller. Change broker/runner contracts. Remove
undo/redo, clipboard, or save/open behavior.

## 5. Waves 3–4 — editor/console/LS, packaging (after G1)

### Z3.1 — `code_editor` kind: zgui-editor + Gleam grammar (Rust)

- Depends: G1 · Size: M · Branch: `z2/z3.1-editor`

**Spec.** In `campy-renderer`: replace the `code_editor` stub with
zgui-editor's `Editor`; `SetCode` sets the buffer; edits emit
`editor:<id>:changed` (debounced ~300 ms); `ReadText` returns the full
source; register `tree-sitter-gleam` in the `LanguageRegistry`
(`language = "gleam"`); `SetMarks` drives diagnostics layers
(squiggles) and search bands; `read-only` supported.

### Z3.2 — `console` kind: zgui-terminal over a BEAM-fed transport (Rust)

- Depends: G1 · Size: M · Branch: `z2/z3.2-console`

**Spec.** A campy `Transport` impl whose read side is a queue fed by
`AppendConsole` (UTF-8 chunks; ANSI escapes flow through — the preview's
`io_lib` output renders); keyboard lines raise
`console:<id>:input`. Scrollback/selection/search come free. `pty` feature
of zgui-terminal stays off (dependencies minimized).

### Z3.3 — Gleam LS ↔ editor (Rust + thin Gleam)

- Depends: Z3.1 · Size: M · Branch: `z2/z3.3-lsp`

**Spec.** Evolve `campy-bridge/src/lsp.rs`: `editor:<id>:changed` drives
incremental `textDocument/didChange` (zgui-editor's replacement events
map 1:1); diagnostics → `SetMarks(control, "diagnostics", spans)`; the
completion request/reply kinds stay (`lsp:completions`), payload gains
`control:` so the IDE can route to the editor's popover.

### Z4.1 — headless smoke suite

- Depends: G1, Z0.2's `ui-testing` driver · Size: M · Branch: `z2/z4.1-smoke`

**Spec.** Port `scripts/smoke_native.py` + the gesture probe to the
headless driver: scripted `SurfaceEvent`s, virtual clock, scene
transcript assertions (a `Dump` NIF returns the window's scene text for
golden comparisons). `just smoke` needs no display; `just smoke-native`
keeps the real-window path for manual passes.

### Z4.2 — packaging & native deps

- Depends: G1 · Size: S · Branch: `z2/z4.2-package`

**Spec.** `scripts/workspace.py` export bundles the wgpu native set
alongside the X11 libs into `generated/native-deps`; `just package`
stays one command; doctor checks the GPU libs.

**Empirically verified on this machine** (strace of the real-window
smoke): the new runtime dlopens **`libvulkan.so.1`** and
**`libdrm.so.2`** (plus the system's own Vulkan ICD drivers and
`libdisplay-info` — those are the target machine's GPU stack and must
NOT be bundled). Extend the existing `generated/native-deps` RPM
extraction to include those two; `doctor` gains a check for
`libvulkan.so.1` on the library path the NIF uses. Document in
README's requirements that a desktop GPU stack (any Vulkan-capable
driver) is now required, replacing the old "software renderer, GPU
optional" note.

### Z4.3 — docs sync

- Size: S · Branch: `z2/z4.3-docs`

**Spec.** `docs/ARCHITECTURE.md` rewritten where it says Slint
(renderer, bindings, reload protocol, IDE surface); README requirements
(+ GPU libs, - `libxkbcommon-x11` only note); MVP state/limits refresh.

## 6. Gates

| Gate | After | Reviewer | What |
| --- | --- | --- | --- |
| G0 | Z0.2 + Wave 1 | GLM-5.3 | Protocol matches §1.4 on both sides; codec v12 clean; CCL table consistent |
| G1 | Wave 2 | GLM-5.3 + user | Manual IDE pass: design, drag, inspect, Run/F7/Stop, F6, console, tabs |
| G2 | Waves 3–4 | GLM-5.3 + user | Editor+LS dogfood pass on `campy-dev.campy`; smoke green headless |

Dispatch order: Z0.2 (coordinator) → Wave 1 parallel → G0 → Wave 2
sequential (Z2.1 → Z2.2 → Z2.3) → G1 → Wave 3 parallel → Wave 4 → G2.

**Punch-list status after Z2.3 (updated by the coordinator's gap-3 fix):**
gaps 1, 3, 4, 5 are CLOSED — reliable Reload for every session (per-run
drain timers, deferred-session window swaps, build-race stalls),
`list` rows emit `selected` with the row text, and the pointer payload
carries `x;y;button;mods` (right-click and ctrl-click). The IDE loop's
list/right-click routing was already in place from Z2.3. Gap 2 is
now CLOSED: a `menu` renders its `model` as a popup of base `control()`
rows at the document root (positioned from the trigger's absolute
rectangle, one `selected` event per item with the label the loop already
routes), which reaches File/Edit/Settings without depending on zgui-ui's
DropdownMenu — whose input path is still the unverified one. Gap 6 is
CLOSED too: a control with a `hint` prop reports `pointer enter`/`leave`
and the loop puts the hint on the status line (restoring the previous
message on leave, and gated by the settings dialog's "Show UI hints").
Still open for G1/Wave 4: gap 7 (console-goto) and Z4.1 (smoke-native
PNG removal).

**Shell layout and controls (after the visual pass).** The shell is no
longer a fixed 1280×860 frame: `shell.layout(width, height)` derives
every pane from the window size, the renderer reports the window's CSS
size on change (a `size` event), and the resize reaches the document as
`SetGeometry` ops — the side panes keep their widths, the centre column,
canvas and console take the rest, and dialogs centre themselves.
Choice rows are real dropdowns on the same popup machinery as menus
(a check on the current value, `selected` with the option text), which
retires the click-to-cycle stopgap.

**Visual pass (live window, first look):** the shell now renders as a
dark IDE rather than a wall of blue buttons. Four causes, all fixed:
the emitter's `class` prop was never applied (so no shell rule matched);
the hand-placed panels declared `row`/`column` layout (so their
coordinates were ignored and children stacked); the window was 1200×800
while the shell is laid out at 1280×860 (Run/Stop off-screen); and the
workspace/project terms were decoded with `binary_to_term(…, [safe])`,
which rejects every file the codec writes (the terms carry the form
model's own atoms, and a Gleam program holds those as binaries) — every
boot silently reset the workspace. Tabs are one button per open module,
list rows mark their active item, inspector choice rows cycle their
options (zgui-ui's `Select` binds two-way and writes back on mount,
which drove the IDE loop one generation per tick).

Screenshots for this work come from `CAMPY_UI_SNAPSHOT=<path>.png`: the
window's own renderer copies the composed frame out once, and
`CAMPY_UI_SNAPSHOT_TRIGGER=<path>` takes one on demand (the debug knob
watches for the file and consumes it). On Wayland nothing outside a
client may read its pixels — KWin's `ScreenShot2` answers only
`xdg-desktop-portal-kde`, the portal prompts a human, and `grim` is not
installed — so reading the composed frame is both cheaper and exactly
what the user sees.

Live pointer injection was attempted through `/dev/uinput` (writable
here; a virtual absolute pointer is visible to KWin like a real
device). It works when the pointer is on the window's output, but this
desktop has two outputs and an absolute device follows the output the
pointer is on, so automated clicks are not reliable across them. The
scripted `ui-testing` driver remains the way to test clicks and keys.

**Designer (G1 item 4).** The gesture model was already there (click
select, drag move with live preview committed on release, eight-grip
resize, marquee, drop-into-container reparenting, undo per gesture).
What was missing was the visible half and the additive selection:

- the eight grips are drawn at the exact points `state` hit-tests
  (one `grip_size` constant, two users), and the module window draws its
  own corner grip while nothing is selected;
- Ctrl or Shift on a press adds the component to the selection or takes
  it out, on empty canvas it leaves the selection alone, and a modified
  marquee *extends* the selection instead of replacing it;
- a multi-selection draws one outline per member (a fixed pool of 24,
  shown or hidden) plus the union box with grips.

Grips, member outlines and the window grip are fixed pools toggled with
`visible`: a selection must not change the document's *shape*, or every
click would need a fresh `LoadUi` instead of a few geometry ops.

**Idle cost, keyboard and theme (after the first live pass).** The drain
ran on an 8 ms `set_interval`, which is a frame per tick: 125 fps on an
idle IDE, a caret that blinked at 125 Hz, and a core burnt doing nothing.
The queue now *wakes* the window instead — a counter written by the BEAM
(and by a close) plus the event loop's own proxy — the window's size
arrives on its own signal, and a full drain batch re-arms itself. An idle
IDE draws no frames at all.

Keys were dead unless a field had been clicked, because the shell's key
handler sits on an element nothing focused. The root now registers as a
window shortcut (it hears unfocused keys), and a focused text control
marks itself so the keys that edit text (Ctrl+C/X/V, Delete, arrows)
stay with it. That is what makes Ctrl+C/X/V (component clipboard), F5/F6/
F7, Ctrl+S/O/N/Q, Ctrl+Z/Y and Escape work at all.

"Update running app" (F6/F7) showed nothing because the host a swap
installs is built in the command drain, outside any window scope: its
`document` was a scope-owned `new_local` signal, disposed before the new
window built its child. The document and the validation tick are now
`ArcRwSignal`s, so a replacement window renders the document it was
handed.

The theme changed our own tokens only, which left the console, the
editor and every zgui-ui control in the theme they were written for (a
dark console in a light window). Both themes now also set
`--zui-color-*`, `--terminal-*`, `--editor-*` and `--syntax-*`.

Console lines now end with CRLF: a terminal moves down on LF and keeps
the column, so every entry started where the previous one ended.

`CAMPY_UI_DEBUG_VIEW` values for a validation run: `settings`, `code`,
`select`, `multi`, `light`, `run`, `run-update`.

**Partial updates.** A document write used to rebuild the whole tree, so
editing one control (or switching module, which changes the canvas subtree)
rebuilt the shell around it. The tree is now built once per window and a
document goes through a reconciler:

- the document is flattened by id, and every container's children are a
  keyed list (`For`) keyed by `(id, shape generation)`;
- a control whose *kind* and *static props* are unchanged keeps its nodes —
  the reload writes the new text, geometry, model, checked/enabled/visible
  into the signals those nodes already watch;
- a control whose shape changed is re-keyed, which rebuilds that row alone;
- the editors and the terminal are rebuilt on every reload: their content
  lives in their own buffer, fed afterwards by `SetCode`/`AppendConsole`,
  so a carried row would show the previous module's source.

Measured with `CAMPY_UI_TRACE=1`: adding one control to a form of 245 is
`reconcile controls=246 rebuilt=1 carried=245`; the same reload with the
editor, raw view and console in the document is `rebuilt=4 carried=242`.
`CAMPY_UI_DEBUG_AFTER=add` makes that structural change after the first
load, so the number can be read against a window already on screen.

What is still sent whole is the document itself: the BEAM answers a
structural change with `LoadUi` (the ops are textual/geometry-level), so
the NIF still carries the full tree. Emitting `InsertControl`/
`RemoveControl`/`MoveControl` instead — and applying them to the flat map —
is the next step; the renderer side no longer needs a new tree for it.

**G1 manual-pass checklist** (run `just run` on a live desktop; every
line must pass or become a filed punch item):

1. Boot: shell renders once; console shows the session-opened line;
   status bar path is correct.
2. Menus: File/Edit/Settings open and every item from the old shell
   fires (New / New module / Open / Save / Save As / Quit; Undo / Redo /
   Copy / Cut / Paste); broken items become punch items.
3. Palette: all 16 tiles visible; clicking places the control; hover
   shows the old hint behavior (status line).
4. Designer: click-select; drag-move with live preview committed on
   release; eight-handle resize; marquee; right-click context menu
   (canvas + control); alignment; Delete key; undo/redo of moves.
5. Inspector: selection drives the `insp:` rows; text/bool/choice edits
   apply; the window (empty-canvas click) shows title/size/layout; the
   trashcan removes.
6. Tabs/navigator: module tabs open/close/switch; projects navigator
   switches; the new-module dialog works.
7. Code view: handler source displays with Gleam highlighting; edits
   mark dirty; Apply persists; diagnostics squiggles appear after an LS
   round trip; completions reach the editor.
8. Console: preview logs render (ANSI colors pass through); input line
   round-trips.
9. Run/F7/Stop on Cat Café: window opens, F7 live-updates, Stop closes.
10. F6 on the IDE itself: rebuild + `LoadUi` swap; workspace survives.
11. Keys: the full binding list from Z2.2's report (Ctrl+N/Shift+N/O/S/
    Shift+S/Q, Z/Shift+Z, C/X/V, F4/F6/F7/F10, Esc, Delete, arrows,
    Enter, Tab).
12. **The zgui-ui A/B**: swap one `button` kind in the renderer to
    zgui-ui `Button`, run, click it — if it fires on a real window,
    zgui-ui is cleared for the shell upgrade wave; if not, file
    upstream (their tests only dispatch via the component testkit).
13. `just dogfood`: the campy-dev project opens in the IDE — modules
    list, external sources display and edit.
