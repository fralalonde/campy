# Phase 2 — wx rewrite: view layer, shell, designer, deploy

This is a dispatch plan. Each task is a self-contained brief: a fresh agent with
only §1 (shared context) and its brief can execute it. Expensive review happens
at gates G0–G4 (§6), not per task.

Goal of the phase, in one sentence: **Campy is a lean standalone BEAM IDDDE built
on OTP wx, where a designed form is canonical JSON, an app is state plus
handlers, and Run deploys to a local peer node and attaches a view.**

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
- Next: **T1.3** IDE model.

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
| `gleam/packages/campy_view` | **new**, the view tree and diff |
| `gleam/packages/campy_wx` | **to build**, wx renderer |
| `gleam/packages/campy_ccl` | retarget: target-neutral widget catalog + prop schema |
| `gleam/packages/campy_project` | **new**, project directory + form documents |
| `gleam/packages/campy_form` | legacy until T1.5; geometry reference for T2.1 |
| `gleam/packages/campy_app` | rewrite: ABI v2 actor |
| `gleam/packages/campy_appgen` | rewrite: v2 source generation |
| `gleam/packages/campy_manifest` | keep (manifest codec, migration, compat) |
| `gleam/packages/campy_broker` | keep build/assemble/store; no network |
| `gleam/packages/campy_peer` | **to build**, client-side node/deploy control |
| `gleam/packages/campy_runner` | rewrite: runner node app + `campy_control` |
| `gleam/packages/campy_ide` | rewrite: display-free IDE state and commands |
| `gleam/packages/campy_ide_wx` | **to build**, the wx shell |
| `gleam/apps/campy_ide` | replaced by the new shell wiring |
| `rust/`, `campy_bridge`, `campy_runtime`, `campy_ui`, `campy_search_box` | delete (T1.5) |
| `campy.campy`, `projects/*.campy` | convert to the JSON project layout (T1.2) |

### 1.4 Conventions and guardrails

1. **Gleam only.** No Rust, no NIFs, no new native code in this phase.
2. New packages go to `gleam/packages/<name>/`, `target = "erlang"`,
   `gleam = ">= 1.16.0 and < 2.0.0"`, gleeunit as a dev dependency. Add the name
   to `PACKAGES` in `scripts/workspace.py`.
3. `campy_view`, `campy_form`, `campy_ccl`, `campy_manifest` stay pure: no wx,
   no distribution, no IO beyond document files.
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

### T1.3 — `campy_ide`: display-free IDE model

- Depends: T1.2 · Size: L · Branch: `p2/t1.3-ide-model`
- Spec: `State` (projects, modules, open tabs, selection, undo snapshots,
  console, settings), commands as pure `(State, Command) -> #(State, List(ViewIntent))`,
  and a headless test suite. No wx, no IO beyond loading/saving documents.
- Acceptance: `just check` green; tests cover open/switch, selection, undo/redo,
  console cap, and save/load round trip.

### T1.4 — `campy_ide_wx`: the shell on wx

- Depends: T0.5, T1.1, T1.3 · Size: L · Branch: `p2/t1.4-shell`
- Wire `campy_ide` intents to renderer patches and wx events to commands.
  Menu, quick toolbar, palette, project/module tree, tabbed editor, Scintilla,
  inspector grid, console, splitters, status line, accelerators, native dialogs.
- Acceptance: the IDE shape from the brief is usable; every panel is data-driven;
  no window reload for ordinary edits.

### T1.5 — Delete the legacy stack

- Depends: T1.4 · Size: M · Branch: `p2/t1.5-remove-legacy`
- Delete `rust/`, `campy_bridge`, `campy_runtime`, `campy_ui`,
  `campy_search_box`, the old `gleam/apps/campy_ide` wiring, Slint emitters,
  NIF staging in `scripts/workspace.py`, and the Cargo recipes in `justfile`.
  Update `PACKAGES`, `.gitignore`, README. Keep `campy_manifest`, `campy_broker`,
  `campy_appgen`, `campy_app` (rewritten in M3).
- Acceptance: `just check` green with no Rust toolchain; repo contains no
  Slint/Rust references outside historical docs.

## 4. M2 — the form designer

- **T2.1** Canvas and overlay: module window, grid, marquee, eight resize
  handles, drag outline, `wxOverlay`-based feedback; geometry from `campy_form`.
- **T2.2** Palette, placement, adoption, z-order, clipboard, undo.
- **T2.3** Inspector (common-property editing) and Events → handler stub.
- **T2.4** Generated Gleam-wx source tab (read-only first), replacing the Slint
  source tab.
- Gate G2: design the Cat Café form from scratch, run it, reopen it, and diff it.

## 5. M3/M4 — run, deploy, debug

- **T3.1** `campy_app` ABI v2 actor (state, `view`, dispatch, reports,
  `state_version`, `migrate`), no polling, no bridge.
- **T3.2** `campy_appgen` v2 (embedded form, generated `init`/`view`, dispatch
  module name, ABI v2 stubs).
- **T3.3** Attach client in the IDE: deploy in-VM first, send `View`, apply diffs,
  route `Event`s, render console reports.
- **T3.4** Code update: build → send artifact to runner → `campy_control.deploy`
  → `code:load_binary` → pause/apply/migrate/resume, failed update is a no-op.
- **T4.1** `campy_peer`: start/stop `:peer` nodes, hidden IDE node, cookie, name,
  health, teardown.
- **T4.2** `campy_runner`: `campy_control` on the node; deploy from binaries,
  start/stop/status/state, forward reports.
- **T4.3** Node manager UI: nodes → apps tree, deploy, version, restart,
  rollback, console lines.
- **T4.4** Debug v1: supervisor tree, process list, app state viewer
  (`:sys.get_state`), `:dbg` trace toggle.
- Gate G4: deploy to a peer node, kill the peer (console reports it), restart,
  redeploy a new version, inspect state.

## 6. Gates

| Gate | After | What must be true |
| --- | --- | --- |
| G0 | T0.5 | Gallery runs in `dev-raw`; focus/caret/scroll survive patches; 500-row update is incremental; mount/patch timings recorded |
| G1 | T1.5 | IDE shape usable; no Rust; `just check` green; legacy gone |
| G2 | T2.4 | Form designed, run, reopened, and diffed from JSON |
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
