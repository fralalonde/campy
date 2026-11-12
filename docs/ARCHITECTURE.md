# Runtime architecture

## Ownership

Each OS application process contains BEAM and the Rust NIF. The Linux UI runtime
owns a single Slint Winit event loop on a dedicated supported thread. Multiple BEAM
actors hold logical sessions. Ordinary controls are nodes, not mandatory actors;
stateful components/windows may have actor owners.

The IDE is a Gleam application using this same runtime, not a separate Rust product.
Rust owns rendering, native integration, and queue transport only.

The NIF supports live Linux sessions and display-free UI compilation. Compilation uses a native worker with an explicit 8 MiB stack, because Slint standard-widget compilation overflows a BEAM scheduler stack. A dirty I/O NIF waits for the result in this bootstrap. Live session NIFs enqueue commands and return immediately; their completions arrive asynchronously. The separate UI thread has its own 8 MiB stack.

## Canonical description

The author edits declarative Gleam. A component description contains interface
descriptors, a visual expression tree, stable IDs, bindings, events, and metadata.
The designer edits this supported source subset; arbitrary computed fragments
are opaque and edited at their definition. Evaluation alone is not enough for
round-trip editing, so source locations and declaration structure must be retained.

Derived artifacts are typed Gleam facades/codecs, Slint source, and diagnostic
source maps. The native bridge interprets generic handles and values; it must not
generate Rust component-specific accessors. Dependency resolution and expression
validation are framework responsibilities.

## Data flow

1. Actor sends a validated UI definition / model batch with a session and generation.
2. Short NIF calls enqueue owned data, returning promptly with enqueue status.
3. The UI thread compiles/creates/updates components and sends asynchronous results.
4. Native callbacks send typed, versioned event payloads to the owner mailbox.
5. Gleam reduces events into a model and effects, then publishes changed properties.

Use bounded queues, explicit completion messages, and ownership checks. A reference
must not grant another actor permission to mutate a session accidentally. Resource
destructors and owner-monitor callbacks set atomic cleanup flags; they never drop live UI
handles on an arbitrary scheduler thread. Native failures can affect the whole VM.

## Bindings

Constants and pure expression ASTs become Slint bindings. Arbitrary Gleam functions
remain on BEAM and publish computed values. Continuous native interaction never
waits synchronously for an actor response. Editable controls apply local edits
immediately; model revisions reconcile updates without feedback loops or stale writes.

Layout compilation is driven by description changes, not keystrokes. Lists use
native models and stable item keys instead of recompiling for every data update.

## Reload protocol

The target protocol is prepare → validate → snapshot/migrate → pause → commit →
resume → retire. Each instance, generation, interface member, and effect has an
identity. Failed preparation does not replace the active UI. Late results are
discarded or explicitly rerouted according to their contract.

BEAM can retain current and old module code, but loading modules is not a global
upgrade transaction. A stable runner resolves replaceable handlers by module,
function, and generation rather than retaining closures into old modules. Migration
decodes a versioned snapshot; it must not cast an old opaque state term to a new type.
Do not create unlimited version-specific module atoms during development.

Development watching demonstrates a stable-ABI, one-module description reload. The
host retains a pure search model and accepted generation. Native window replacement
also copies compatible public properties and dimensions; it commits the description
after the UI-thread completion event. It soft-purges old code,
loads the new module, generates Slint, prepares the native candidate, and commits the
description only after successful replacement. On failure the accepted UI generation stays unchanged, but the newly
loaded BEAM code is not rolled back. Full transactional behavior is M3.

## Dependencies and native boundaries

- `campy_ui`: pure description/validation/generation; no NIF dependency.
- `campy_search_box`: depends on `campy_ui`; portable component implementation.
- `campy_runtime`: lifecycle, generation, and future state/effect coordination.
- `campy_bridge`: sole owner of Gleam native externals.
- `campy_ide`: composes packages and runs the application.
- `campy-bridge`: Rustler ABI and scheduler-safe command transport.
- `campy-renderer`: Slint interpreter and thread-confined live UI state.

See [ADR 0001](adr/0001-linux-ui-thread.md) for bounded session transport,
owner monitoring, Linux startup, and the current polling/reload tradeoffs.

Use OTP `priv/` assets for installed packages. Public package interfaces/source
are additionally needed for statically typed consumer builds; runtime discovery
uses versioned descriptors and decoders. Package loading is code execution within
the VM and is not an untrusted-code sandbox.

## IDE surface

`campy_ccl` is the Campy Component Library: a dependency-free catalog of the
basic LCL-inspired controls. It owns each component's key, label, category,
default size/text, child acceptance, and event name. Both the designer palette
and the form metadata derive from this catalog; rendering targets Slint's
widget model where one exists (LCL properties are mapped to Slint semantics).

`campy_form` owns the designer model (a flat list of absolutely positioned
controls plus a parent map for adoption, an alignment map, and per-container
layouts), handler-name derivation and stub generation, the versioned project
codec (v8), the workspace codec (v1), and the standalone form-window emitter. Panels and the window root accept children; new/pasted controls are
adopted by the selected accepting component, its first accepting ancestor, or the
window. Copy/cut/paste snapshots a whole subtree and re-keys it on paste. A
project is a set of modules, each with one form and its handler source; Campy
opens its own project file (whose first module is the Cat Café demo) and creates
it on first run.

`campy_ide/ide_ui` renders the whole IDE shell — one-row menus/palette/Run
controls, Projects navigator, module navigator, tabbed module editor, object
inspector, code view, generated-Slint view, console pane, and settings/project
dialogs — as one interpreted Slint component per structure. A single top-right
button switches the editor between the form and the handler code; the form
editor's bottom tabs switch between the actual design and the generated Slint
source. The CCL palette shares the top row with Run/Stop and the arrow/box
component selector. A separate console pane sits below the editor canvas. The window uses a preferred (not fixed) size, so
the window manager can resize and maximize it. Every panel is data-driven and
every interaction returns through the generic callback channel, so the IDE uses
exactly the same bridge as a designed app. Choosing the window (clicking the
empty canvas) shows its title/size/layout in the inspector and makes it the
adoption root.

F6 is a development hot-reload path. `campy_hot_ffi:reload/0` runs `gleam build`
in the app package, then hot-loads every currently loaded `campy_*` Beam from the
build ebin (`campy_ide` included; the NIF wrapper is excluded). The IDE loop
re-enters through `campy_hot_ffi:continue/7`, an external call into
`campy_ide:loop/7`, so the next iteration uses the newly loaded loop and dispatch.
The host then regenerates the Slint shell from the new `ide_ui` and submits
`LoadUi` with the next generation, resetting the diff snapshot so every scalar
and model is re-applied to the refreshed window. The BEAM process, workspace, and
project state survive. Rust/NIF changes and changes to record/state shapes still
require a process restart.

The preview window is also model-driven. `campy_form/live_preview` emits a shell
with a `PreviewControl` model, window title/size, layout switches, and one
generic `event(string)` callback. `campy_ide/live_preview_ui` applies a snapshot
(title, size, layout, control model, alignment/pictures). Run loads the shell
once; F7 re-applies the active module's snapshot to the same session, so the
running app updates without `LoadUi`, a window restart, or losing app state.
Events arrive as control-id/event pairs and are mapped to the derived handler
names. The static `preview` emitter remains for the generated-Slint tab.

Projects are independent documents inside a workspace; switching projects
changes the active project, module tabs, and editor models without reloading the
window. The workspace and the active project are reconciled on each host
transition and auto-saved to `projects/workspace.campy` (full project snapshots),
so edits survive a restart even without an explicit project Save. Deleting a
project removes only the workspace entry.

The shell is loaded once and is not replaced by ordinary edits; the explicit F6
hot reload submits a new `LoadUi` and re-applies all state. A root `FocusScope` owns the global
keyboard bindings (undo/redo, clipboard, Delete, save/open, Run/Stop); it is the
window's forward focus and the canvas re-focuses it on selection clicks, while
text fields accept their own editing keys first. A snapshot history in
`campy_ide/state` records committed document changes (form, inspector, module
creation, handler Apply) and supports global undo/redo; navigation and settings
changes are not recorded. System file dialogs are invoked through a small Erlang
FFI that runs Zenity/KDialog when a display and helper are available and reports
unavailability so the host falls back to the in-window dialog. Scalar state is
root properties
and the dynamic collections (navigator modules, open tabs, canvas controls, and
code lines) are Slint models rendered by `for` loops. The host diffs the desired
values and pushes `SetText`/`SetBool`/`SetInt`/`SetColor` plus `SetModel` (a
small generic value tree of text/bool/int/list/struct/image converted to Slint
structs and models). Theme colors are root color properties so the color scheme
can change live; Slint's `Palette.color-scheme` is updated through an
`init`/`changed` handler for the Light scheme.
Structural edits — add/delete control, open module, apply code, load project —
are model updates, so focus, selection, scroll, and the window itself survive.
`LoadUi` is only used once at startup.

The Free designer renders the form as a module window: its title bar moves a
per-module canvas position (UI-only) and its corner handle resizes the form
(committed to the form model). The form's controls remain form-relative.

The console stores a capped line log in IDE state. Preview lifecycle and
callback events are appended (the app's visible stdout); the input line is sent
to the console (stdin is logged/reserved until handler execution lands).

The optional MCP server is a small Erlang HTTP process bound to 127.0.0.1. It
implements MCP initialize, tools/list and tools/call over JSON-RPC; tool calls
are forwarded to the IDE loop, which owns the current state and replies with
text. It is disabled by default and started/stopped from Settings → Agent.

Layout is part of the form: **Free** uses absolute geometry (drag moves and any
of the eight corner/side handles resize; the UI tracks the gesture locally and
sends the deltas once on release), while **Column**/**Row** wrap the control
model in Slint `VerticalLayout`/`HorizontalLayout`. Panels and group boxes can
also choose Free/Column/Row for their direct children; the host resolves those
bounds. A move drop re-parents the control to the smallest accepting panel under
its center (or to the window when dropped outside), and only highlights when
the parent would change; `render_controls` sorts containers before their
children so adopted controls draw above their panel. Free controls may also
declare an LCL-style **alignment** (Top/Bottom/Left/Right/Client/Fill),
relative to the parent container (or the window at the root). Fill uses the
inner parent area minus the space occupied by siblings around the control.
Containers have a **Border** margin; aligned and arranged children resolve
against the inset inner rectangle. Designer and preview resolve the same
geometry. Container layouts take precedence over alignment. The Free
canvas uses a contrasting background and light grid, and module-window moves and
resizes show an outline preview before committing on release.

The inspector edits the active module's form; events create or open a handler
stub in that module's source, and the code view displays the highlighted source
or edits one handler at a time. The Settings → Editor dialog changes the code
font family/size and the color scheme. Project files are compressed, versioned
Erlang terms validated on load; v1 (single form), v2 (modules), v3 (layout),
v4 (parent map), v5 (alignment), v6 (per-container layouts), and v7 (icons)
files upgrade to v8 (container borders). Cargo builds use
`scripts/cargo.sh`, which selects the compatible glibc toolchain when installed
and avoids producing a NIF that requires a newer glibc than the runtime. The selected component can be
removed with the inspector trashcan or the Delete key; both go through the
undoable `delete_selected` transition. The UI command queue is bounded and the
snapshot harness uses a ReadText barrier to drain updates before capturing.

## Bootstrap validation

The native compiler worker's larger stack is required in practice: compiling the
full standard-widget search box on a BEAM dirty scheduler caused a native crash,
while simple empty-window validation succeeded. The runner additionally requires
runtime completion markers because Gleam 1.16 can return success after a native
child-process crash. The integration test compiles the actual generated search box.

## Primary references

- [Slint threading and event loop](https://docs.slint.dev/latest/docs/rust/slint/)
- [Slint interpreter compiler](https://docs.slint.dev/latest/docs/rust/slint_interpreter/struct.Compiler)
- [Dynamic component API](https://docs.slint.dev/latest/docs/rust/slint_interpreter/struct.ComponentInstance)
- [Experimental component embedding](https://github.com/slint-ui/slint/issues/2390)
- [Erlang NIF lifecycle, scheduling, and messaging](https://www.erlang.org/doc/apps/erts/erl_nif.html)
- [BEAM module code replacement](https://www.erlang.org/doc/system/code_loading.html)
- [Gleam hot-reload limitations](https://gleam.run/frequently-asked-questions/)
- [Slint licensing FAQ](https://github.com/slint-ui/slint/blob/master/FAQ.md)

