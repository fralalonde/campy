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
gap 3 (Reload) is CLOSED — per-run drain timers, deferred-session window
swaps (v1 parity), and build-race stalls; integration-tested for both
the initial and the deferred window. Still open for G1/Wave 4: gap 1
(`list` rows emit nothing — the renderer needs row activation), gap 2
(`menu` has no popup), gaps 4/5 (pointer payload lacks button and
modifiers — right-click and ctrl-click; keyboard mitigations exist),
gaps 6/7 (hover, console-goto), and Z4.1 (smoke-native PNG removal).

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
