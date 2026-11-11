# MVP: one portable search box in a live Gleam application

## Definition of done

`just run` opens a native Campy window from a Gleam/BEAM application. The window
contains a search box defined entirely in a separately packaged Gleam component.
Typing updates its model through typed events. Changing its label, layout, or
compatible behavior updates the running application and preserves the query.
Invalid updates leave the accepted version usable. Loading a new compatible
component package requires no Cargo invocation or native runtime rebuild.

The IDE MVP adds a component palette, property inspector, and preview of that
same description. A general code editor, debugger, marketplace, mobile targets,
database designer, arbitrary state migrations, and production release packaging
are outside this MVP.

## Bootstrap delivered in this repository

- Separate Cargo workspace and Gleam package tree, orchestrated with `just`.
- Real in-process Rustler NIF with protocol handshake and Slint compilation.
- A constrained description AST for a row, query field, button, and bindings.
- An all-Gleam search-box description plus model and typed event examples.
- A running host that accepts new description generations after module reload.
- Native compilation, schema identity, stale-generation, escaping, and behavior tests.

The bootstrap schema hardcodes `query`, `busy`, `query-changed`, and `search`.
That is intentional scope for the first spike, not the final extensibility model.
The M0 host now renders native controls and routes their callback notifications to
Gleam. Search effects and busy completion are still M2 work.

## M0 — in-process native window startup: implemented

Verified on Linux Wayland and X11. `just run` opens the native host; `just dev`
reloads the sample description. See [ADR 0001](adr/0001-linux-ui-thread.md).
Native test input uses Slint window events; physical keyboard/IME integration is
not covered by that automated input adapter.

Deliverables:

1. A dedicated Linux Winit UI thread, supported by the pinned backend.
2. NIF `open_session()`, bounded `submit(session, command)` and `close_session`.
   Ownership is the calling actor, rather than an arbitrary caller-supplied PID.
3. UI-thread-owned component handles; NIF resources contain only thread-safe IDs,
   ownership information, and queue endpoints.
4. Asynchronous native callbacks delivered as BEAM messages, plus owner monitoring.
5. A window with the current generated search-box UI launched by `just run`.

Acceptance:

- Assert and log the OS process ID and UI thread identity during startup.
- Demonstrate Slint and BEAM sharing the OS process without blocking a scheduler
  in an event loop. A dirty NIF alone does not satisfy UI-thread requirements.
- Type, resize, and close the window while a BEAM heartbeat continues.
- Killing the owner schedules cleanup on the UI thread and does not leak the window.
- Unsupported startup paths return explicit errors; they do not silently use IPC.

Resolved Linux gate: the pinned Winit backend explicitly allows a dedicated
thread on Wayland/X11. No patched OTP launcher or BEAM embedding library was needed.
The runtime logs its process/thread identity, asserts its thread confinement, and
keeps the native loop outside BEAM schedulers. Unsupported OSes return errors.

## Visual designer slice — implemented (foundation for M4)

`just run` opens **Campy Studio**, a classic RAD-style IDE built from the same
interpreted Slint runtime it designs for. It is a targeted slice of M4 taken
early so the IDE can be used and evaluated; M1–M3 below are still the long-term
architecture work. Campy opens its own workspace (`projects/workspace.campy`,
created on first run); a workspace holds one or more projects, and each project
is a set of modules with a form and handler source.

Delivered:

1. Tool palette: Run opens the **active module's** form in a second native
   window; Stop closes it.
2. Workspace navigator (left): a project list with switch/create/delete, and a
   `ListView` of the active project's modules; click to open or activate a
   module, `+` to add one.
3. Tabbed module editor (centre): one tab per opened module (closable). A single
   top-right button switches between the **form editor** and the module's
   **handler code**. The form editor's bottom tabs are **UI (actual)** and
   **Code (Slint file)**; the latter shows the generated, read-only Slint source.
4. Components + object inspector (right): the **CCL** palette is a `ListView`
   driven by the shared component catalog (Label, Edit, Memo, Button, Check box,
   Radio button, Combo box, List, Slider, Progress, Panel, Group box, Picture);
   the Properties/Events inspector shares the pane.
5. File menu: New project / New module / Open… / Save / Save As… / Quit.
   Projects are versioned, compressed Erlang terms (`projects/*.campy`, v5),
   validated on load; v1–v4 files are upgraded, including form layout, the
   adoption parent map, and alignment. Workspaces are versioned compressed terms
   (`projects/workspace.campy`, v1) holding full project snapshots and the active
   project path.
6. Form editor: absolutely positioned canvas with click-to-select, cursor drag to
   move, and a corner handle to resize (committed once on release); the same
   form model drives the run window. Clicking the empty canvas selects the
   **window** itself. A form can use Free, Column, or Row layout; Column/Row
   delegate placement to Slint layouts and need no geometry messages.
7. CCL components: Label, Edit, Memo, Button, Check box, Radio button, Combo
   box, List (sample rows), Slider, Progress, Panel, Group box, and Picture.
   Picture stores a path in its text field (editable in the inspector or via the
   **Choose picture…** path dialog) and renders in the designer and run window.
   The `campy_ccl` package is the single catalog used for keys, labels, default
   sizes/text, event names, and palette rows by both the designer and the IDE.
8. Alignment: Free-layout controls can use LCL-style Top, Bottom, Left, Right, or
   Client alignment. The preview binds aligned geometry to Slint's parent
   width/height; the designer computes the same geometry. Column/Row layouts
   ignore alignment. (LCL's dock ordering and anchors are intentionally not
   reproduced yet; Slint's layout model is authoritative.)
9. Adoption and clipboard: panels/group boxes (and the window root) accept
   children. New and
   pasted controls go to the selected component when it accepts children, else
   its first accepting ancestor, else the window. Edit → Copy / Cut / Paste
   duplicates whole subtrees with fresh names and positions; moving a panel moves
   its descendants.
10. Object inspector: properties (name, text, x, y, w, h, align, enabled,
    visible) and an Events tab. Clicking `OnClick` / `OnTextChanged` opens the handler in the
   central Code view and generates a stub when one does not exist.
11. Code view: syntax-highlighted read-only Gleam (comments, keywords, strings,
    numbers, types, punctuation) plus a focused multi-line editor that edits the
    selected handler with Apply/Cancel. The caret is placed on the stub body via
    `set-selection-offsets`.
12. Settings → Editor…: font family, font size, and color scheme (Dark, Light,
    Solarized). The scheme updates the shell/code colors through `SetColor` and
    the native widget palette through Slint's `Palette.color-scheme`.
13. `just snapshot-ide` renders the designer, CCL widgets, code view, handler editor, file
    dialog, settings dialog, Slint source tab, light scheme, run window, new
    components, layout mode, and property-only updates to `generated/*.png`.
14. Fully dynamic shell: the window is generated once and ordinary edits never
    reload it. Navigator rows, module tabs, canvas controls, palette rows, and
    code lines are Slint models; scalar state is root properties.
    Adding/deleting controls, opening modules, applying handler code, and loading
    projects are model updates — no reload, focus loss, or flicker. F6 is the
    explicit hot-reload exception.
15. The default project's modules are the **Cat Café** demo (a panel with adopted
    picture/label/list/edit/button children, handler stubs, and a generated cat
    illustration) and **CCL Widgets** (every CCL control plus top/bottom aligned
    labels).
16. Native file dialogs: Open, Save As, and the Picture picker use Zenity or
    KDialog when available (absolute paths are relativized to the project root
    or app directory); otherwise the in-window path dialog is the fallback.
17. Global undo/redo: one snapshot history covers form edits, inspector changes,
    layout changes, paste/cut, module creation, stub creation, and handler
    Apply. Undo/Redo live in the Edit menu and toolbar; Ctrl+Z,
    Ctrl+Shift+Z/Ctrl+Y.
18. Keyboard shortcuts (Ctrl+N/O/S/Shift+S/Q, Ctrl+C/X/V, Delete, F5, F6, F7,
    Shift+F5, Escape) are bound through a root `FocusScope`/`KeyBinding`; text
    fields keep their local clipboard/delete behavior. The selected component is
    deleted with the Delete key or the small trashcan in the inspector.
19. Hot reload (F6): the in-IDE action rebuilds the Gleam app, hot-loads the
    new Beams into the running VM, and reloads the Slint shell from the new
    `ide_ui` source. The loop re-enters through a stable external call, so the
    new loop/dispatch/state code is used; a full scalar/model sync restores the
    UI. Rust/NIF and state-shape changes still require a restart.
20. Live app update (F7): Run opens a model-driven preview shell. F7 re-sends
    the active form's title, size, layout, controls, alignment, and image model
    to the existing session, so the running app updates in place without a
    window reload or restart. The generated Slint tab still shows the static
    source.
21. Workspace manager: projects can be switched, created (generated
    `projects/project-N.campy` paths and one Main module), and deleted from the
    workspace. The shell is not reloaded when switching: projects/modules/controls
    are models and scalars. The workspace and all project edits are auto-saved;
    deleting a project leaves its file on disk.

Limitations of this slice: the chrome itself is generated from project state
rather than being an editable campy module (the form model still lacks
menu/tab/tree/text-edit primitives); the palette adds by click rather than
drag-and-drop; undo is snapshot-based per committed action (no character-level
text coalescing); the Slint source tab is generated and read-only; handlers are
saved as Gleam source but the running form does not execute them (clicks are
logged); and the bridge still has no generic model batch commands. Native dialogs
depend on a desktop helper; headless or helper-less systems use the in-window
dialog. Those belong to M1–M3/M4 proper. The multi-session command-race fix in the renderer is a
prerequisite for Run/Stop and is covered by the IDE tests.

## M1 — shared component schema and generated API

Deliverables:

1. Replace hardcoded search properties/events with versioned descriptors.
2. Typed property/event handles and serializable expression nodes.
3. A deterministic generator for a typed Gleam facade, codecs, and Slint.
4. Stable IDs for components, interface members, and nodes, separate from names.
5. Search-box `query: String`, `busy: Bool`, `QueryChanged(String)`, and `Search`.

Acceptance:

- A property type mismatch fails before creating a native instance.
- Renaming a member preserves its ID and updates all generated projections.
- Designer metadata, bridge validation, and Gleam codecs derive from one schema.
- Generated facades do not import the description module: generation is a separate
  build phase, avoiding a circular dependency. Runtime plugins use descriptors.
- A fixture containing quotes, Unicode, and Slint interpolation-like text compiles safely.

## M2 — render and interact through the generic bridge

Deliverables:

1. Route native events to the owning Gleam runtime actor and search-box reducer.
2. Publish property/model batches back to the UI with instance and revision IDs.
3. Keep text editing, cursor movement, scrolling, and layout local to Slint.
4. Show the current query and search result/status in the host window.

Acceptance:

- Typing a character updates `query` without recompiling UI source.
- Search sets busy state and disables the button; a simulated completion clears it.
- Stale model revisions cannot replace newer text, and writes do not echo as user events.
- Event queues are bounded; text changes can coalesce, semantic actions cannot disappear.
- Two sessions can coexist in one VM with independent state and ownership checks.

## M3 — package loading and UI hot reload

Deliverables:

1. Load a package directory containing BEAM modules, assets, descriptor version,
   runtime capability requirements, and the public Gleam interface/source for builds.
2. Generate and compile candidate UI through the installed interpreter runtime.
3. Compile/validate, snapshot, prepare, pause dispatch, commit, and retire generations.
4. Keep state owned by the long-lived actor, separate from replaceable visuals.
5. A defined UI replacement boundary; initially the containing preview window.

Acceptance:

- Install a second component package while Campy is running, without rebuilding Rust.
- Edit the search label/layout and retain a nonempty query across successful reload.
- Malformed Gleam, malformed Slint, incompatible capabilities, and mismatched schema
  preserve the accepted instance and produce visible diagnostics.
- Reject late events and async results from retired generations.
- Preserve compatible focus/selection/scroll state; defer replacement during IME composition.
- Candidate behavior runs through a version-aware dispatch boundary. Loading a new
  BEAM module alone is not an atomic code/UI update and is not sufficient rollback.

The bootstrap watcher only reloads `campy_search_box` with a stable ABI. Its
last-known-good guarantee applies to the accepted UI description, not a rollback
of BEAM module code. State shape/behavior migrations are not implemented.

Slint's separately compiled subtree embedding is experimental in 1.18.1. Start
with replacing the interpreted preview window. Evaluate `ComponentContainer`
behind a version-pinned adapter before promising seamless panel replacement.

## M4 — first RAD surface, using the same runtime

Deliverables:

- A palette containing SearchBox and a few primitives.
- A preview using the real component instantiation path.
- Selection overlay and a property inspector editing the canonical description.
- Semantic undo/redo and source-aware changes to the declarative Gleam subset.

Acceptance:

- Change SearchBox's label in the inspector and see the Gleam description change.
- Change the description in an editor and see the inspector and preview update.
- Save/reopen the project with stable IDs, layout, and bindings intact.
- Use the same SearchBox package in Campy's own component-palette search UI.

## Risks and decision gates

| Gate | Required evidence |
| --- | --- |
| Native event-loop startup | M0 live window and responsive VM on each claimed platform |
| Slint dynamic embedding | Pinned adapter prototype or accepted window replacement UX |
| API stability | Versioned descriptors and capability negotiation before third-party packages |
| Hot reload safety | Generation-aware dispatch and explicit state migration boundaries |
| Distribution rights | Clarify Slint API-exposure restrictions for a RAD SDK; select suitable terms |

## Suggested implementation order

M0 and the visual designer slice are implemented. M1 is still the next
architectural step: keep it focused on the search-box schema so the designer's
hardcoded control bindings become generic descriptors. Complete M2 before
promising live model batches, then demonstrate M3 package loading/reload, and
finally finish M4 with drag-and-drop, inspector-driven behavior, undo/redo, and
source-aware hand edits.

