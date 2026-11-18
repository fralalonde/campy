# Phase 2 — wx rewrite: view layer, shell, designer, deploy

This is a dispatch plan. Each task is a self-contained brief: a fresh agent with
only §1 (shared context) and its brief can execute it. Expensive review happens
at gates G0–G4 (§6), not per task.

Goal of the phase, in one sentence: **Campy is a lean standalone BEAM IDDDE built
on OTP wx, where a designed form is canonical JSON, an app is state plus
handlers, and Run deploys to a local peer node and attaches a view.**

## 0. Resuming cold (handoff)

**Original objective (unchanged).** Phase 2 replaces the Slint/Rust prototype
with a lean standalone BEAM IDDDE on OTP wx. The lasting asset is the view
layer: a target-neutral `campy_view` tree + patches, canonical JSON projects,
an app = state + ABI v2 handlers, and later deploy to local peer nodes. HTMX
rendering and editor plugins are target-neutral later additions and are **not**
built now. User priorities: standalone first, plugins lowest, no Slint, no P1.3
port runner, ABI v2 now, local peers.

**Toolkit decision.** Stay on OTP wx/GTK. Qt was rejected: OTP has no Qt binding,
wxQt is experimental/incomplete, and OTP's wx driver cannot be rebuilt against
it. Option 2 (native children + selection chrome) is implemented on wx.

**Current position (2026-11-17).**
- M1 complete (gate G1 passed). **T2.1, T2.2, T2.3, T2.4 and T2.5 complete
  and verified under Xvfb.** The IDE now uses the reference information
  architecture (menus + compact toolbar/palette strip, Projects/Modules
  navigator, centre Form/Code/Source + console, right Properties/Events dock,
  status bar) and thin blue selection chrome with body-drag movement.
- 250 tests green: `campy_view` 73, `campy_wx` 14, `campy_project` 13,
  `campy_ide_model` 52, `campy_design` 31, `campy_catalog` 9,
  `campy_manifest` 27, `campy_source` 9, `campy_ide_wx` 22.
- `just check` is green headlessly. On this Fedora 46 host, OTP 28's crypto NIF
  no longer loads against the system OpenSSL (missing `EVP_sm4_cbc`); run
  `LD_LIBRARY_PATH=<compatible OpenSSL 3 dir> just check` until OTP is rebuilt.
  The IDE and wx tests do not need crypto.
- Save/reopen on a throwaway copy writes canonical `form.json`/`handlers.gleam`
  and `CAMPY_WX_SMOKE=1` mounts the saved project.
- **T3.1** `campy_app` — done (2026-11-18). The ABI v2 actor: `Event`
  (control/key/value/generation), `Effect` (Log/Notify/Stop), `Reply`
  (View/Report/Notify/Version/Stopped), `Spec` (name, module, form document,
  state_version, optional migrate closure), and `Msg`
  (EventReceived/Upgrade/SnapshotRequest/StopRequest). Dispatch resolves
  `<control>_<event>` from the form (the control must exist and declare the
  key), checks `function_exported/3`, and applies `handler/2` through
  `campy_app_ffi` (raises are contained as HandlerError reports). After every
  applied event the actor publishes `view/1`'s document with an incremented
  generation. `Upgrade` runs the new module's `migrate/2` when the carried
  version differs and republishes; `SnapshotRequest` returns the raw state for
  the T4.4 viewer. 11 headless tests cover dispatch, no-ops, contained errors,
  Stop effects/messages, upgrade/no-op, snapshot, and the naming rule.
- **T3.2** `campy_appgen` — done (2026-11-18). `generate(slug, document,
  handlers)` emits one dispatch module per form (`campy_app_<slug>`):
  `view/1` embeds the designed document through `campy_source`'s public
  emitters, the user's `handlers.gleam` is appended verbatim with its own
  leading imports hoisted (dropping the runtime modules the generated section
  imports), and declared events without handlers get ABI v2 no-op stubs.
  Validation rejects an empty source, missing `pub type State`/`init/0`, a
  user-defined `view/1`, and an invalid slug with precise messages.
  Compile proof: both demo modules were generated into a throwaway package
  with only `campy_view` + `campy_app` path deps; `gleam build` succeeded and
  calling the generated `view/1`/`init/0` from Erlang returned the embedded
  tree and `{state, 0}`. 10 headless tests.
- **T3.3** Attach client — done (2026-11-18). Run/Stop tools deploy the
  active form in-VM: `campy_appgen.generate` writes the scratch package under
  `<root>/generated/apps` (CAMPY_ROOT or the cwd-derived repo root),
  `campy_ide_wx_ffi:compile_and_load/2` runs `gleam build`, adds the ebin to
  the code path and loads the module; the IDE then starts the `campy_app`
  actor with the module's own subject as the dispatch channel. Replies are
  drained every loop pass: `View` grafts the published document into a live
  **Run** page (the form root becomes a panel; free-layout sizers now lay out
  via `relayout_free_children` — a panel under a free-layout parent is never
  reached by the frame layout pass), `Report`/`Notified`/`Version` go to the
  console. Shell events whose control is in the published view and declared
  the key are routed to the actor as `EventReceived`; the demo greeter's Run
  click produces "greeted 1 times", "notify: Hello from Campy!" and view
  generation 2. Note: the Scintilla console flushes its pixels lazily under
  the headless probe (the widget buffer is correct; later GUI activity
  repaints it) — stdout `[app]` lines and later shots show the reports.
  275 tests total.
- **T3.4** Code update — done (2026-11-18). `campy_app.load_code(module,
  beam_path)` loads a compiled beam in place via `code:load_binary`
  (charlist path required), and `pause`/`resume` suspend/resume the app actor
  around the load (`gleam/otp/system`). In the IDE, **Save while running**
  hot-updates: regenerate via appgen → write → `gleam build` → pause →
  load_code → resume → `Upgrade(module, old, new)`; the actor runs the new
  module's `migrate/2` and republishes `Version` + `View`. A failed step is a
  no-op log and leaves the running version untouched. Verified headlessly
  (deploy proof: v1 greet → v2 with `migrate/2` → the next event logs
  "v2 greeted 2" on migrated state) and in the IDE probe (Save while running
  → "updated greeter to version 2", "app state version 2", view generation
  3). The in-VM part of `campy_control.deploy` from the ADR is this flow; the
  remote-node part lands with M4. 278 tests total.

**Next step.** **Gate G2**: design the demo form from scratch in the shell,
save it, inspect/diff the canonical JSON, and reopen it. Do not start M3 (ABI v2
runtime, appgen, Run) until G2 passes.

**Layout.**
```
gleam/packages: campy_view campy_wx campy_project campy_ide_model
                campy_design campy_catalog campy_manifest campy_source
                campy_app campy_appgen campy_peer campy_runner
gleam/apps:     campy_ide_wx
examples/demo   canonical project (greeter, notes)
scripts:        workspace.py (build/test runner), ui_probe.sh (X11 probe)
docs:           PHASE2.md, adr/0003-0005
```

**Commands (from the repo root; run GUI/wx work in `dev-raw`).**
```sh
flatpak-spawn --host toolbox run -c dev-raw sh -lc \
  'cd /var/home/fralalonde/Code/campy && just check'
just run          # IDE on examples/demo (CAMPY_PROJECT=<dir> to change)
just smoke        # scripted mount/open/close
scripts/ui_probe.sh xvfb   # Xvfb + xdotool; screenshots in generated/ui/
```
The probe requires Xvfb, xdotool, ImageMagick, and openbox (installed in
`dev-raw`). Read `generated/ui/*.png` to verify UI changes.

**Continuation invariants (learned the hard way).**
1. All wx calls go through `campy_wx_native.erl`. Use **class-specific**
   `connect` (`wxPanel:connect`, `wxStaticText:connect`, `wxMiniFrame:connect`);
   generic `wxWindow:connect` silently fails.
2. Mouse event types are converted to binaries in the adapter; Gleam patterns
   match strings, not atoms.
3. Sizer inserts use `sizer_index` (count only layout children); chrome children
   (menus, toolbar, status, pages) never occupy sizer slots. Min sizes apply per
   dimension.
4. Designer hit-testing resolves the **document** layout and compares against
   `layout.root`; the design view renames the root to `canvas`.
5. Any geometry commit runs `campy_design.freeze` first (materializes resolved
   coordinates, sets free layout, drops `border`/`gap`), then `set_rect`; group
   moves commit every rect in one undo entry.
6. Selection chrome is **painted by the canvas' own paint handler** (outline,
   9 px handles, grip, marquee) and interaction is **hit-tested on canvas
   events** (`campy_ide_wx.handle_role_at`). There are no chrome widgets at
   all: top-level mini-frames each became a separate taskbar entry on Wayland,
   and child panels swallowed the pointer. Hide chrome when the selection is
   empty; resize handles only for a single selection; cursor feedback comes
   from `set_canvas_cursor`.
7. The `design` prop selects design-mode events; do not overload `events`
   containing `select`, because the module tree uses that key for its own
   selection.
8. `campy_design.design_view` produces the canvas subtree; the document itself
   stays the source of truth. The inspector shows resolved rects.
9. Grid edits arrive as `wxGridEvent` records, not `wxCommandEvent`s. The
   adapter reads the event's own row/col and cell text; `getGridCursorRow` is
   already on the next cell when Enter moves the cursor before the reader.
10. Read-only Scintilla panes ignore `SCI_SETTEXT` in this wx build. Clear
    read-only, set the text, then restore the flag (`editor_set/3`).
11. Tree selection arrives as a `wxTreeEvent` (`command_tree_sel_changed`), not
    a `wxCommandEvent`; map that one type to `command` and leave
    expand/collapse as non-events.

## Status (2026-11-16)

- **T0.1** ADRs 0003 (wx), 0004 (view/projection/ABI v2), 0005 (source format) —
  done in the working tree
- **T0.2** `campy_view` — view tree, values, patches, structural diff, validation
  plus a reference applier (49 tests) — done in the working tree
- **T0.3** `campy_view/codec` — canonical JSON, `Document` wrapper, unknown-field
  preservation (71 tests total) — done in the working tree
- **T0.4** `campy_wx` core renderer — done; 13 pure tests; smoke in `dev-raw`
  mounts the gallery in ~110 ms and applies patches in 0–1 ms
- **T0.5** gallery harness — done; the G0 focus/caret/scroll checks are manual
  and still owed
- **T1.2** `campy_project` — project directory, canonical `campy.json`,
  module/form documents, handler files (13 tests) — done; geometry resolution
  moves to T2.1
- **T1.1** shell primitives — done; menus, toolbar, status, notebook, tree,
  grid, Scintilla, file dialogs; `shell_demo` smoke mounts in ~42 ms
- **T1.3** `campy_ide_model` — display-free state, commands, console, undo/redo
  (16 tests) — done
- **T1.4** `campy_ide_wx` — runnable shell over a project directory, sample
  fixture, smoke ~38 ms (5 tests) — done
- **T1.5** legacy removal — done. `rust/`, Slint packages, the bridge/runtime,
  the old IDE app, `campy_ccl`, `campy_form`, `campy_app`, `campy_appgen`,
  `campy_broker`, `campy_runner`, NIF staging, and the legacy project files are
  gone. `just check` (Gleam only) is green.
- **Gate G1 passed** (human check). M1 is complete.
- **T2.1 (part 1)** `campy_design` — absolute geometry, hit-testing, move/resize
  (19 tests) — done.
- **T2.1 (part 2)** canvas, selection, and gestures — **done and verified under
  Xvfb with xdotool + screenshots** (`scripts/ui_probe.sh`): native controls on
  a painted grid, hit-tested canvas selection, Ctrl-toggle multi-selection,
  group move, nine chrome handles (eight resize + move grip) with capture,
  live previews, commits through `campy_design.freeze` + `set_rect` + model
  undo, and module-switch persistence.
- Selection chrome lives in borderless, always-on-top **mini-frames**, not child
  panels: GTK draws child panels above controls but routes input to the control
  underneath, so panels could not be clicked. Popups were also input-dead in
  this environment; mini-frames work. The inspector shows the union rectangle
  for a multi-selection.
- **Marquee selection** — done: drag from empty canvas captures the pointer,
  draws a four-strip rectangle (blue mini-frames), and selects every control it
  intersects on release. Empty-canvas hit-testing now compares against the
  layout root, not the design-view id (that mismatch was selecting the form
  root).
- **T2.1 is complete and verified**: click/Ctrl-click/marquee selection, single
  resize, single and group move, undo per gesture, inspector geometry, module
  switch persistence.
- **T2.2** palette, placement, adoption, clipboard, z-order, and undo — done
  (2026-11-17). `campy_catalog` is the target-neutral widget table; the left
  pane has a palette; click-to-arm and drag-on-canvas placement adopt the
  deepest container; copy/cut/paste/duplicate/delete use fresh ids; a single
  move can cross containers; front/back reorder child order. Every command is
  a model undo entry. Verified under Xvfb: panel drag-place, button adoption,
  copy/paste, duplicate, delete, undo, and reparent to root.
- **T2.3** editable inspector and events — done (2026-11-17). Single selection
  shows resolved absolute geometry (invariant 8), `kind`, parent and text in a
  compact two-field-per-row grid; x/y/w/h use wx's integer cell editor and text
  uses the text editor. Edits dispatch `SetControlRect`/`SetControlProp` through
  the model, so each one is an undo entry and the canvas diff updates. Multi
  selection shows only shared properties with differing values blank and is
  read-only. An events list beside the grid lists the selected control's
  declared events; clicking one opens Code and appends an ABI v2
  `pub fn <control>_<event>(state, event)` stub when missing (one undo entry,
  scrolled into view). Verified under Xvfb: x 477→500, text → `Hello T2.3`,
  canvas updated, click event appended `button_1_click` and opened its source.
- Bugs found by the probe: mouse event types were atoms while Gleam patterns
  were binaries; `wxWindow:connect` silently failed for concrete widgets
  (class-specific `connect` is required); sizer inserts used raw child indexes
  (chrome children inflated the index); zero-width min sizes skipped heights;
  column-layout edits snapped back until the container was frozen to free
  layout; the inspector showed document props instead of resolved geometry;
  grid edits are `wxGridEvent`s and the cursor has already moved when read;
  `wxGridCellNumberEditor` needs both min and max or GTK aborts the editor.
- **T2.4** generated source tab — done (2026-11-17). See §4 for delivered and
  deviations. 240 tests.
- Toolkit decision: stay on OTP wx/GTK. Qt has no OTP binding; wxQt exists but is
  incomplete and OTP's driver cannot be rebuilt against it. Option 2 (native
  children + selection chrome) is therefore built on wx/GTK: real child
  controls, handle widgets as raised siblings, `wxOverlay` for marquee and drag
  outlines.

Superseded and not to be built: everything in `docs/PHASE1.md` §5 (P1.3 port
runner, ETF framing, runner child process). Distribution via `:peer` replaces it.

Non-goals for this phase: editor plugins (VS Code/JetBrains), the HTMX renderer,
JSON wire mapping, remote clusters, iroh transport, signing, federation, metrics.
The component model must not block them; nothing else is built for them.

## 1. Shared context

### 1.1 What Campy is

A Gleam-first RAD IDE (IDDDE) for the BEAM: design a form, edit handlers, run it
as a supervised OTP app, deploy it to a peer node, inspect it while it runs. All
UI is OTP `wx`; there is no Rust in the product.

Read before starting: `docs/adr/0003-wx-ui-toolkit.md`,
`docs/adr/0004-view-tree-and-projection.md`, `docs/adr/0005-source-format.md`.

### 1.2 Core model

- **View** = `campy_view.Node` tree: `kind, id, key, props, events, children`.
  Plain data, canonically serialized to JSON on disk.
- **Patch** = `SetProps | SetEvents | Insert | Remove | Order | Replace`.
  `campy_view/diff.diff(previous, next)` produces them; clients apply them to
  live widgets. Children match by identity (`key` else `id`).
- **Form document** = the view tree plus module metadata, in
  `modules/<slug>/form.json`.
- **App** = supervised actor with `State`, `init/0`, `view/1`, per-control
  `(state, event)` handlers, `state_version`, optional `migrate/2`.
- **Runner** = an OTP node started with `:peer`, speaking `campy_control`
  (`deploy/start/stop/status/state/trace`) over distribution. Beams travel as
  binaries and load with `code:load_binary`.
- **Client** = anything that mounts a view and sends events: the IDE shell, a
  preview window, later a browser.

### 1.3 Codebase map

| Path | State |
| --- | --- |
| `gleam/packages/campy_view` | view tree, values, patches, diff, canonical JSON |
| `gleam/packages/campy_wx` | wx renderer, shell primitives, gallery/shell demos |
| `gleam/packages/campy_project` | project directory, module/form documents |
| `gleam/packages/campy_ide_model` | display-free IDE state and commands |
| `gleam/packages/campy_manifest` | artifact manifest, migration, compatibility |
| `gleam/packages/campy_source` | generated `campy_view` construction source (read-only output) |
| `gleam/apps/campy_ide_wx` | the IDE shell on wx |
| `examples/demo` | two-module fixture project in the canonical format |
| to build | `campy_peer`, `campy_runner`, `campy_app`, `campy_appgen`, `campy_broker` (M3/M4) |

### 1.4 Conventions and guardrails

1. **Gleam only.** No Rust, no NIFs, no new native code in this phase.
2. New packages go to `gleam/packages/<name>/`, `target = "erlang"`,
   `gleam = ">= 1.16.0 and < 2.0.0"`, gleeunit as a dev dependency. Add the name
   to `PACKAGES` in `scripts/workspace.py`.
3. `campy_view`, `campy_catalog`, `campy_source`, `campy_manifest` stay pure:
   no wx, no distribution, no IO beyond document files.
4. On-disk documents are canonical JSON per ADR 0005. Never add a second source
   format.
5. `just fmt` then `just check` must pass before finishing. The thinker machine
   runs Gleam headlessly; **wx windows can only be checked in the Fedora
   `dev-raw` toolbox** (`flatpak-spawn --host toolbox run -c dev-raw ...` when
   the OpenCode flatpak has host access, otherwise ask the user to run it).
6. Do not modify the legacy stack except in T1.5's deletion list. Do not
   "fix" Slint code.
7. Stay inside the brief's Files list. If the spec is wrong or forces an
   undesigned decision, stop and report.
8. Every task runs on branch `p2/<task-id>`. Do not mix tasks on one branch.

### 1.5 Dispatch template

> You are implementing task `<ID> — <title>` in the Campy repository at
> `/var/home/fralalonde/Code/campy`. Read `docs/PHASE2.md` §1 and §<brief>, and
> the three ADRs. Follow the brief exactly, including Files and Do-not. Run
> `just fmt` and `just check` before finishing. If anything is ambiguous or the
> spec appears wrong, stop and report instead of deciding. Report: files
> changed, tests added, check result, deviations, and any manual wx checks still
> owed.

## 2. M0 — the view layer is proven

### T0.1 — ADRs 0003–0005

- Depends: none · Size: S · Done.
- `docs/adr/0003-wx-ui-toolkit.md`, `0004-view-tree-and-projection.md`,
  `0005-source-format.md`.

### T0.2 — `campy_view`: tree, values, patches, diff, validation

- Depends: none · Size: M · Done.
- `gleam/packages/campy_view/**`.
- Types: `Value`, `Node`, `Patch`. API: constructors, `identity`, `normalize`,
  `prop`, `ids`, `validate`, `diff.diff/2`.
- Acceptance met: 35 tests, including keyed insert/remove/reorder, identity
  change → `Replace`, normalization equality, duplicate detection.

### T0.3 — Canonical JSON codec for view documents — done

- Depends: T0.2 · Size: M · Risk: low · Done (71 tests).
- Goal: the text format of ADR 0005, implemented once for any `Node` tree.
- Delivered:
  1. `campy_view/codec.gleam`: `encode(Node) -> String`,
     `decode(String) -> Result(Node, String)`, plus
     `encode_document(Document)` / `decode_document(String)` for the
     `{"schema": <int>, "view": <node>, ...extra}` wrapper. Decoding uses OTP's
     `json` module through `campy_view_ffi.erl`; no new dependencies.
  2. Encoding: fixed key order `kind, id, key (omitted when none), props,
     events (omitted when empty), children (omitted when empty)`, then extras
     sorted; props sorted; 2-space indent, LF, trailing newline; integers stay
     integers; floats always render with a decimal point.
  3. `decode` validates with `campy_view.validate` and reports paths
     (`$.children[0]: missing "id"`).
  4. `Node.extra` and `Document.extra` preserve unknown fields; `VNull`
     preserves JSON null. `diff` ignores extras: they are document metadata and
     produce no render patches.
  5. Canonical form: `encode(decode(s)) == s` for canonical input; encoding is
     idempotent. Schema policy belongs to the caller (a newer schema decodes).
- Files: `campy_view/src/campy_view.gleam` (Node change), new
  `campy_view/src/campy_view/codec.gleam`, `campy_view_ffi.erl`, tests.
- Do not: touch any other package; add a JSON library.
- Acceptance: `just check` green; tests for round-trip, idempotence, key order,
  unicode, floats, numbers that look like ints, unknown-key preservation, and
  malformed input errors.

### T0.4 — `campy_wx` core renderer — done

- Depends: T0.2 · Size: L · Risk: medium-high · 13 pure tests; wx smoke passed.
- Delivered:
  1. `campy_wx` public API: `start/3`, `mount/2`, `apply/2`, `next/2`,
     `close/1`, `focus/2`, `now_ms`, `getenv`. The calling process owns every
     wx object; there is no worker process and no command queue.
  2. `campy_wx/native.gleam` + `campy_wx_native.erl`: the adapter. All wx atoms,
     option lists, records, event connections, and value read-back live there;
     Gleam sees opaque handles and typed values.
  3. Kinds: `panel`, `group` (rendered as a panel for now), `label`, `button`,
     `checkbox`, `radio`, `choice`, `list`, `text`, `memo`, `slider`,
     `progress`, `picture`, and window/form roots.
  4. Layout: `column`/`row` create a box sizer on the container; free children
     use absolute position/size. Inserts honor the patch index; `Order` detaches
     and re-inserts in sizer order, or raises in free order.
  5. Props: text/title, value, checked, selection, items, enabled, visible,
     x/y/w/h. Unchanged values are never written; `freeze`/`thaw` and one
     `layout` wrap each batch.
  6. Events: the `#wx{}` message is the single receive point. `next/2` maps the
     wx id to the view widget, derives the key by kind, reads the value, and
     only emits event keys the node declared. Other messages are returned to the
     caller unchanged.
- Deviations: `group` has no static-box chrome yet (T2); text changes are
  forwarded per event (no coalescing yet); changing a container's `layout` at
  runtime is not supported (remount instead).
- Files: `campy_wx/**`.

### T0.5 — Gallery harness and gate G0 — done

- Depends: T0.4 · Size: S · Done (manual checks owed).
- `campy_wx/gallery.gleam`: full control set, 500-row list, keyed row
  insert/remove/reorder, enable toggle, live status patches, mount/patch timing
  lines. `CAMPY_WX_SMOKE=1` runs a scripted mount → 4 patch batches → close and
  exits 0.
- Verified in `dev-raw`: mount ~110 ms, patches 0–1 ms.
- Gate G0 still needs a human in front of the window: type in the text field
  while periodic patches land (caret/focus must not move), scroll the 500-row
  list and patch (scroll must not jump), click Mutate through the four phases.

## 3. M1 — the shell

### T1.1 — wx shell primitives — done

- Depends: T0.4 · Size: M · Done (14 tests; shell smoke in `dev-raw`).
- Delivered as view kinds: `menubar`, `menu`, `menuitem` (frame menu bar),
  `toolbar`, `tool`, `status`, `notebook`, `page`, `tree`, `grid`, `editor`
  (Scintilla). Chrome kinds are attached by their parent kind rather than a
  sizer; layout children support a `grow` prop that maps to sizer proportion 1.
- Imperative fill helpers: `set_tree/3` (keyed tree items; selection reports the
  key), `set_grid/3` (rows of cells; edits report row/col/text), `set_editor/4`
  (text + read-only), `set_status/2`, `select_page/3`.
- Native file dialogs: `open_dialog/2`, `save_dialog/3` in the adapter.
- Events: menu items and tools arrive as `click`; notebook as `change` (index);
  tree as `select` (key); grid as `change` (row/col/text map).
- `campy_wx/shell_demo` assembles every region; `CAMPY_WX_SMOKE=1` fills them,
  sets status, closes, exits 0.
- Deviations: `wxNotebook` instead of `wxAuiNotebook` (docking later);
  splitters/dockable panes deferred to T1.4 if sizers are insufficient; toolbar
  tools use text labels with an empty bitmap; no custom paint canvas yet (T2.1).

### T1.2 — `campy_project`: project and form documents — done

- Depends: T0.3 · Size: M · Done (13 tests, sandbox and `dev-raw`).
- Delivered:
  1. `campy_project` (new package; the legacy `campy_form` stays until T1.5):
     `Project(title, modules, extra)`, `Module(slug, form: campy_view.Document,
     handlers)`.
  2. Layout: `campy.json`, `modules/<slug>/form.json`,
     `modules/<slug>/handlers.gleam`. Handler source is written verbatim.
  3. `load/1`, `save/2`: canonical JSON through `campy_view/codec`
     (`parse_json`/`write_json` are now public). Project schema 1; newer or
     older schemas are refused with an explicit message until a migration path
     exists.
  4. Module slugs are validated (`[a-z0-9_]`, unique); form roots must be
     `form` or `window`.
  5. Unknown project fields are preserved as JSON and re-emitted sorted.
  6. `handler_name(control, event)` (ABI v2 naming) and `module/2`.
- Deferred: geometry resolution (free/column/row, alignment, border, adoption)
  and hit-testing are designer concerns and move to T2.1. The old geometry code
  remains the reference.
- Files: `campy_project/**`, `campy_view/src/campy_view/codec.gleam` (public
  parse/write).

### T1.3 — `campy_ide_model`: display-free IDE model — done

- Depends: T1.2 · Size: M · Done (16 tests).
- Package `campy_ide_model` (named to avoid colliding with the legacy
  `campy_ide` app until T1.5).
- Delivered: `State` (project, open tabs, active module, selection, console,
  undo/redo snapshots, status, code/form toggle), `Command`, pure `update/2`,
  `open_module/2` (Result), `close_module/2`, `select_controls/2`,
  `commit/2` (no-op commits are not recorded), `undo`, `redo`, `log` (500-line
  cap, newest first), `set_status`, `toggle_code_view`, `active_module`,
  `console_text`, `status_line`.
- Deviation: commands return `State`, not `#(State, List(ViewIntent))`. With
  one shell present, the shell reads the state and re-renders; intents get
  introduced only if a second observer (MCP/plugin) needs them.
- Files: `campy_ide_model/**`, `scripts/workspace.py`.

### T1.4 — `campy_ide_wx`: the shell on wx — done

- Depends: T0.5, T1.1, T1.3 · Size: L · Done (5 tests; smoke ~38 ms).
- App `gleam/apps/campy_ide_wx`; sample project `examples/demo` (two modules,
  canonical JSON, ABI v2 handler stubs).
- Delivered: window with menu bar (File/Edit/View), toolbar, status bar, module
  tree, tabbed editor (Scintilla), console pane (read-only Scintilla), and an
  inspector grid. Events dispatch into `campy_ide_model`: tree selection opens a
  module, Save writes the project, Undo/Redo update history, Toggle flips the
  code-view flag.
- Refresh policy: the tree is built once at startup; the code editor is only
  rewritten when the active module changes; the console only when it grows; the
  grid and status line update on every command. This preserves editor focus,
  caret, and scroll across unrelated events.
- Deviations: no form preview/designer yet (M2); one Code page rather than one
  tab per module; no Open dialog or MCP yet; `Toggle` changes model state but
  has no visible second view until the form canvas lands.
- Launch: `cd gleam/apps/campy_ide_wx && CAMPY_PROJECT=../../../examples/demo
  gleam run`; smoke with `CAMPY_WX_SMOKE=1`.

### T1.5 — Delete the legacy stack — done

- Depends: T1.4 · Size: M · Done.
- Removed: `rust/`, `scripts/cargo.sh`, the NIF staging and packaging paths,
  `campy_bridge`, `campy_runtime`, `campy_ui`, `campy_search_box`,
  `campy_form`, `campy_app`, `campy_appgen`, `campy_broker`, `campy_runner`,
  `gleam/apps/campy_ide`, `campy.campy`, `projects/`, the old screenshots under
  `generated/`, and the Slint-era just recipes.
- `campy_ccl` was deleted as well: it was unused by the new renderer and still
  carried Slint vocabulary. The widget catalog returns in T2.2 with kinds,
  property schemas, and defaults expressed for the target-neutral model.
- `campy_manifest` is kept (pure, useful for M3/M4); it no longer references
  the legacy codec in its docs.
- `scripts/workspace.py` and `justfile` are rewritten around the new packages:
  `doctor`, `run`, `smoke`, `build`, `fmt`, `fmt-check`, `test`, `check`,
  `clean`. `README.md` and `.gitignore` describe the new tree.
- `just check` passes in the headless sandbox; `just smoke` mounts the IDE on
  `examples/demo` in `dev-raw`.

## 4. M2 — the form designer

### T2.1 — Designer canvas and geometry — done

- Depends: T1.4 · Size: L.
- **Part 1, done:** `campy_design` — pure resolution of a form tree into
  absolute rectangles. Parent-relative coordinates, container borders, column/
  row stacking with gaps, top/bottom/left/right/client alignment, last-painted
  hit-testing, deepest-container hit-testing, and move/resize/set-rect edits
  that clamp to a minimum and clear alignment on an explicit drag. Golden tests
  cover each rule.
- **Part 2, delivered:** `canvas` kind hosting real wx children at the
  resolved rectangles; painted grid and frame; design-mode selection via
  per-control mouse/command events (`design` prop, so the module tree keeps its
  normal select semantics); four raised corner handle widgets; Form and Code
  pages; the inspector reflects the canvas selection, and `campy_design` gives
  the handle rectangle.
- **Part 2, delivered:** a move grip and eight resize handles, each a raised
  sibling widget with mouse capture; live widget previews during the drag; the
  commit goes through `campy_design.set_rect` and `campy_ide_model.commit` so
  undo works. Handles stay at the original rect during the gesture and
  reposition on commit (moving them would shift the captured coordinate base).
- **Completed in T2.1:** marquee selection (mini-frame strips), Ctrl-toggle
  multi-select, directional cursors on the handles, group move, and undo per
  gesture.
- Acceptance met: design the demo form's layout by dragging/resizing controls;
  selection and inspector agree; column/row forms are frozen to free layout on
  the first geometry edit.

### T2.2 — Palette, placement, adoption, clipboard, undo — done

- Depends: T2.1 · Size: L · Done (2026-11-17).
- Delivered:
  1. `campy_catalog` (new pure package): target-neutral widget table (kind,
     label, category, declared events), default sizes and properties, and
     `make`/`make_at`. The palette, designer defaults, and later handler
     generation share one description.
  2. A palette list in the left pane. Selecting an item arms placement; a
     canvas click places the default size, a canvas drag places the drawn
     rectangle. Placement freezes column/row documents first and adopts the
     deepest accepting container under the drop point. Design-mode panels and
     groups get a subtle tint so empty containers are visible.
  3. Move between containers: a single moved control released over another
     container is reparented and keeps its absolute position. Commits convert
     preview rectangles back to parent-relative document coordinates, including
     group moves where a container and a child are both selected.
  4. Clipboard: copy/cut/paste top-level selected subtrees with fresh globally
     unique ids (keys dropped on copies); paste into a selected container, or
     after the selection. Duplicate offsets by 16 px and selects the copies.
     Delete removes selected subtrees.
  5. Z-order via child order: Bring to front / Send to back.
  6. Every command ends in `campy_ide_model.commit`, so each gesture is one
     undo entry. Placement, paste, and duplicate select the new controls.
  7. Audit fixes: `campy_view.diff` hoists every `Remove` to the front of the
     batch, so a cross-parent move (remove old id, insert same id) is safe for
     any applier, and the wx applier also partitions removals first; clipboard
     entries carry canvas-absolute rects and paste converts/clamps them into the
     target container; unchanged drags and a zero-delta grip click do not
     reparent, freeze, or record undo; Ctrl-click works on native widgets and
     design mode no longer connects command events that would collapse the
     toggle; inserted siblings are re-raised in document order (sizer inserts
     use the document index); z-order freezes only when the reordered parent is
     a sizer and is a no-op when already front/back; the inspector reports
     resolved absolute geometry; switching modules disarms placement.
- Acceptance met: add controls, adopt into a container, move a control to
  another container/root, bring/send, duplicate, delete, and undo each step.
- Verified with `scripts/ui_probe.sh xvfb`: arm Panel, drag-place it, place a
  Button inside (inspector `parent=panel_1`), copy/paste (`button_2`),
  duplicate (`button_3`), delete, undo, then drag the button out to the root
  (inspector `parent=root`).
- Deviation: drag-to-place starts on the canvas after arming, rather than
  dragging a payload out of the palette list; `wxListBox` does not expose a
  reliable drag source. Categories/search are deferred.

### T2.3 — Inspector and events — done

- Depends: T2.2 · Size: M · Done (2026-11-17; 226 tests).
- Delivered:
  1. The inspector is a compact two-field/value-pairs-per-row grid (rather than
     one field per row) so all fields stay visible in the fixed 170 px pane
     without scrolling or reflowing the palette. Each value cell is typed: x/y
     and w/h use `wxGridCellNumberEditor` (w/h minimum `campy_design.min_size`),
     everything else uses the text editor.
  2. Single selection shows id, kind, parent, resolved absolute x/y/w/h, and
     text. Multi-selection shows only values shared by every selected control;
     differing values are blank, and grid edits are read-only.
  3. Model commands `SetControlRect(id, Rect)`, `SetControlProp(id, name,
     Value)`, `SetHandlers(text)`, and `OpenHandler(control, event)`. Geometry
     goes through `commit_geometry`, so sizer forms freeze, sizes clamp, and an
     unchanged rect is a no-op. Every change is one undo entry.
  4. An events list (~220 px) beside the grid lists the selected control's
     declared events from the document (the design view rewrites events to
     `select`, so it must not be read). Clicking an event opens the Code page;
     a missing handler appends an ABI v2 stub named by
     `campy_project.handler_name` and scrolls it into view. `handler_exists` is
     a `pub fn <name>(` substring check.
  5. `campy_wx` gained `set_items` for list/choice fills, grid editor helpers,
     and `scroll_editor_to_end`; `campy_design.set_prop`/`set_node_prop` are
     public. Only x/y/w/h/text value cells are editable; identity, kind,
     parent, and summary cells are read-only.
- Acceptance met: edited a geometry cell (x 477→500) and a text cell
  (`Hello T2.3`) through the inspector; the canvas updated and undo advanced;
  clicking the button's `click` event appended `button_1_click` and opened the
  Code page at the stub. Verified with `scripts/ui_probe.sh xvfb`
  (`t23-inspector-single`, `t23-inspector-x-edited`,
  `t23-inspector-text-edited`, `t23-handler-opened`, `t23-handler-stub`).
- Deviation: the inspector uses two field/value pairs per row (value columns 1
  and 3) instead of one pair per row; fields are still resolved from the label
  left of the edited cell, never from a selection-specific row index.

### T2.4 — Generated source tab — done (2026-11-17)

- Read-only generated Gleam construction source for the active form, replacing
  the Slint source tab of the prototype. Doubles as the export path.
- Interpretation: the output is a target-neutral `campy_view.Node` construction
  module (ADR 0004), not direct wx native calls. `form.json` remains the only
  source format (ADR 0005); the text is derived, read-only output and is never
  loaded back.
- Delivered:
  1. `campy_source` (new pure package, no wx/IO): `generate(slug, document)`
     renders a deterministic module header, the public `campy_view` DSL import,
     and `pub fn view() -> Node` with `with_key` / `with_props` /
     `with_events` / `with_children` only when set. Props are normalized and
     sorted; strings are escaped for Gleam (quotes, backslash, LF, CR, TAB,
     other control chars as `\u{...}`); floats carry a decimal point or
     exponent; 2-space indent and one trailing newline. `Node.extra` is omitted
     from the runtime view (documented in the header) because it is document
     metadata, not render data.
  2. The IDE notebook has Form, Code, and Source pages. Model state gains
     `source_view` plus `ToggleSourceView`; Form/Code/Source are mutually
     exclusive. The View menu has a "Generated source" entry, and OpenHandler
     still opens Code. `page_index` selects page 2 for Source.
  3. `refresh` regenerates and rewrites the read-only `source` editor on module
     change and form change; it compares the rendered text so console, status,
     and selection events leave it untouched. The Source page updates after a
     designer edit (absolute x 500→550 became parent-relative `VInt(71)` →
     `VInt(121)` inside `panel_1`) and after switching modules (greeter →
     notes).
  4. Tests: `campy_source` exact output, escaping, floats, deterministic prop
     order, empty children, nested values, `extra` omission, demo greeter
     structure; model page exclusivity and command dispatch; app `page_index`
     plus `source_text` regeneration on form edits. 240 tests total.
  5. Compile proof: both `examples/demo` modules were generated into a throwaway
     package under `/tmp/opencode` with only a path dependency on `campy_view`
     and `gleam build` succeeded (only unused-import warnings; the required
     import line lists every value constructor).
- Acceptance met: generated code matches the canvas structure and compiles as a
  standalone module skeleton. Verified with `scripts/ui_probe.sh xvfb`
  (`t24-source`, `t24-source-end`, `t24-form-edited`, `t24-source-updated`,
  `t24-source-notes`, `t24-view-menu`, `t24-menu-source`).
- End-to-end persistence check: the probe was run against a throwaway copy of
  `examples/demo` with `CAMPY_PROBE_SAVE=1`, which clicks Save. The resulting
  canonical `form.json` contains the placed `panel_1`, its adopted `button_1`
  with text `Hello T2.3` and parent-relative `x: 121`, and `handlers.gleam`
  ends with the ABI v2 `button_1_click` stub. Reopening that project with
  `CAMPY_WX_SMOKE=1` mounts and selects successfully.
- Bugs found by the probe: read-only Scintilla silently ignores `SCI_SETTEXT`
  (clear read-only around the write), and tree selection arrives as a
  `wxTreeEvent` rather than a `wxCommandEvent`, so module switching never
  dispatched. Both are fixed in the adapter (invariants 10–11).
- Deviation: Source is a third notebook page plus a View menu item; no toolbar
  button was added to keep the calibrated probe/toolbar coordinates stable.

### T2.5 — IDE shell redesign (G2 feedback) — done (2026-11-17)

- Depends: T2.4 · Size: L · Done. 250 tests.
- Reference: `docs/images/campy-studio.png` and
  `main:gleam/apps/campy_ide/src/campy_ide/shell.gleam`. The shell now matches
  that information architecture: menus with shortcut hints, a compact text-only
  toolbar, a 16-button palette strip, left Projects/Modules navigator, centre
  Form/Code/Source notebook with a bottom console, right 330 px
  Properties/Events dock, and a status bar. Window 1280×860; probe 1600×1000.
- Delivered:
  1. **Navigator + palette.** Left pane is two `wxListBox` sections (project
     title, module slugs, active module highlighted). The palette moved to a
     compact strip under the toolbar: 16 full-name text buttons with
     `Name — click, then drag on the form` tooltips. Clicking arms placement;
     the armed button is highlighted and the status bar shows a hint.
  2. **Centre.** Active module + `Canvas 600 × 400` header, Form/Code/Source
     notebook, `Console` header with stopped/running state and Clear, and a
     read-only ~150 px console editor.
  3. **Inspector dock.** Selection header (`button_1 — button`,
     `Window — root`, `N selected`) + Delete button; native `wxNotebook` with
     `Properties` and `Events`. Properties is a one-field-per-row `wxGrid` with
     wx row/column labels and grid lines hidden, 22 px rows, a 110 px label
     column and the value column filling the rest. Each row is label + value;
     identity fields are read-only; x/y/w/h use numeric validation and
     text/title use the text editor. Multi-selection shows common values with blanks
     and is read-only. With no selection the dock inspects the window
     (title/w/h/layout/module/history); window w/h are set as root properties and
     do not freeze a column/row form. Events lists only the selected control's
     declared events; selecting one appends the ABI v2 stub when missing and
     opens Code.
  4. **Selection UX.** The chrome is painted in the canvas' buffered paint DC:
     a 2 px blue outline 2 px outside the control, nine 9 px hollow handles on
     the corners and edge midpoints (single selection), a 36x12 grip inside the
     top-left, and the marquee outline. Because the chrome is pixels, it can
     never be misplaced, swallow clicks, or show up in the task switcher; it
     repaints on `show_selection`/`show_marquee`. Handles and the move gesture
     are **hit-tested on canvas events** (`handle_role_at`, ±6 px zones,
     corners first); drag gestures use GTK's implicit grab on the pressed
     widget; a click without motion is a model no-op. Ctrl-click toggles,
     marquee still selects; chrome hides off the Form page.
  5. **Shortcuts.** A page-aware `wxAcceleratorTable` handles Ctrl+S/Q,
     Ctrl+1/2/3 and Escape even inside grid editors; `char_hook` on the canvas
     and design widgets handles Ctrl+Z/Y, Ctrl+X/C/V, Ctrl+D and Delete on the
     Form page. Text shortcuts are omitted on Code/Source so Scintilla keeps
     them. Menu labels carry the same hints, and Help > Keyboard shortcuts opens
     a native dialog. Toolbar/menu actions remain the reliable clipboard path
     while a native text widget owns focus (see deviation).
  6. **Probe.** `scripts/ui_probe.sh` uses a 1600×1000 Xvfb screen and
     recalibrated client coordinates; new screenshots cover the full shell,
     selection outline, body drag, vertical Properties, inspector edit/undo/redo,
     palette armed, placement, Events, handler stub, text edit, Source, menus,
     Help dialog and tooltip.
- Deviations:
  - `char_hook` is connected to the canvas and design widgets, not the frame:
    the frame connection consumed character events for `wxGrid`'s editor and
    double-fired with accelerators on this GTK build.
  - While a native text widget owns GTK focus, GTK consumes Ctrl+C/X/V before
    the app receives them. The toolbar/menu equivalents always work. Ctrl+S/Q,
    Ctrl+Z, Ctrl+1/2/3, Delete and Escape work from the normal canvas focus;
    this is a remaining G2 polish item rather than hidden.
  - The palette strip uses full names (16 buttons fit at 1280 px); the placement
    sentence is in each tooltip.
  - wx's `wxGridCellNumberEditor` spin field refused keyboard text in this build,
    but the numeric cells work when the value column is clicked (the probe
    clicks the value column, not the label column); no workaround was needed in
    the app.
- Acceptance: the full-shell screenshot matches the reference IA side by side;
  all T2.1–T2.4 behaviour still works; the probe runs and was read; `just check`
  is green (250 tests). Save/reopen on a throwaway copy writes canonical
  `form.json` (free layout, `button_1`, text `Hello T2.5`) and the
  `button_1_click` ABI v2 stub; `CAMPY_WX_SMOKE=1` reopens it.

- Gate G2: design the demo form from scratch, save, inspect/diff the JSON, and
  reopen it. The plan's "run it" step belongs to M3.

## 5. M3/M4 — run, deploy, debug

- **T3.1** `campy_app` ABI v2 actor — done (2026-11-18). See the T3.1 status
  bullet above.
- **T3.2** `campy_appgen` v2 — done (2026-11-18). See the T3.2 status bullet
  above.
- **T3.3** Attach client in the IDE — done (2026-11-18). See the T3.3 status
  bullet above.
- **T3.4** Code update — done (2026-11-18). See the T3.4 status bullet above.
- **T4.1** `campy_peer` — done (2026-11-18). See the T4.1 status bullet above.
- **T4.2** `campy_runner` — done (2026-11-18). See the T4.2 status bullet above.
- **T4.3** Node manager UI — done (2026-11-18). See the T4.3 status bullet above.
- **T4.4** Debug v1: supervisor tree, process list, app state viewer
  (`:sys.get_state`), `:dbg` trace toggle.
- Gate G4: deploy to a peer node, kill the peer (console reports it), restart,
  redeploy a new version, inspect state.

## 6. Gates

| Gate | After | What must be true |
| --- | --- | --- |
| G0 | T0.5 | Gallery runs in `dev-raw`; focus/caret/scroll survive patches; 500-row update is incremental; mount/patch timings recorded |
| G1 | T1.5 | IDE shape usable; no Rust; `just check` green; legacy gone |
| G2 | T2.5 | Form designed, saved, reopened, and diffed from JSON (Run is M3) |
| G3 | T3.4 | Handler state flows; failed update is a no-op with a report |
| G4 | T4.4 | Peer deploy/restart/rollback/debug demonstrated |

## 7. Order

```
Wave 1: T0.3  T1.1  T1.2        (T0.3 first; T1.1/T1.2 in parallel)
Wave 2: T0.4  T1.3              (after T0.3)
Wave 3: T0.5  T1.4              (after T0.4 / T1.3)
Wave 4: T1.5  T2.1–T2.4
Wave 5: T3.1–T3.4
Wave 6: T4.1–T4.4
```
