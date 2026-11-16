# ADR 0003: wxWidgets replaces Slint as the UI toolkit

Status: accepted. Supersedes [ADR 0001](0001-linux-ui-thread.md).

## Context

The prototype renders through Slint inside a Rust NIF that owns a dedicated
Winit thread (ADR 0001). That arrangement bought a native window from the BEAM
without blocking a scheduler, but it costs a Rust build chain, NIF staging, a
runtime-compiled UI source and interpreter, open licensing questions for a RAD
SDK, and a widget set that is weaker than a desktop IDE needs. The objective has
also changed: the target is a lean, standalone BEAM IDDDE that is itself a node
in a BEAM cluster, not a Slint showcase.

OTP's `wx` application is a first-class Erlang application wrapping the native
toolkit. It ships with OTP, runs its own event loop and delivers events as Erlang
messages, and exposes the widget set an IDE actually needs: `wxStyledTextCtrl`
(Scintilla), `wxAuiNotebook`/`wxAuiManager`, `wxTreeCtrl`, `wxListCtrl`,
`wxGrid`, `wxSplitterWindow`, `wxStatusBar`, `wxToolBar`, `wxWebView`, native
file dialogs, and accelerator tables. The verified target is OTP 28.5 with
`wx-2.5.4.1` in the Fedora `dev-raw` toolbox.

## Decision

`wx` is the only UI toolkit for Campy.

1. **No Rust for UI.** `campy-bridge` and `campy-renderer` are deleted, along
   with NIF staging and the dedicated UI thread. UI code runs in the BEAM, in
   the wx process that owns each object.
2. **The UI is declarative data, not a declarative language.** A view is a
   `campy_view.Node` tree (kind, stable id, optional key, props, declared
   events, children). Renderers interpret it; `campy_view/diff` turns one tree
   into patches. Nodes are ordinary Gleam values and canonical JSON on disk.
3. **One renderer, two modes.** The form designer and the running app use the
   same wx renderer. Design mode adds selection, handles, grid, and overlay
   painting; live mode routes events to the app. They cannot drift.
4. **Native widgets over custom chrome.** The shell uses `wxAuiNotebook` for
   tabs and docking, `wxTreeCtrl` for projects/modules/nodes, `wxStyledTextCtrl`
   for code, `wxGrid` for the inspector, `wxSplitterWindow` for panes,
   `wxStatusBar`, `wxToolBar`, native menus, and native file dialogs. Palette
   drag uses mouse capture because drop-target classes are not exposed.
5. **Dynamics are patches.** Property updates, keyed inserts/removals, and child
   order are applied inside `freeze`/`thaw` with one layout pass. Values that did
   not change are never written, which preserves caret, selection, and scroll.
6. **Binding gaps are routed around, not worked around with a NIF.** The binding
   has no timers, property grid, data view, drop targets, or ribbon. Timers use
   `erlang:send_after`; the inspector uses `wxGrid`; large collections use
   `wxTreeCtrl`/`wxListCtrl`; drag uses mouse events.

## Consequences

- The build is pure Gleam/Erlang. Packaging needs OTP with `wx` and the native
  toolkit libraries, not a Rust toolchain.
- ADR 0001's thread, ownership, and queue machinery are void. wx owns its event
  loop; the IDE's shell process owns the widgets and normalizes events.
- Runtime UI reload from generated source disappears. Hot reload now re-mounts
  the view tree from newly loaded modules and re-applies state.
- Gained: real code editing (Scintilla), trees, tabs, docking, splitters, native
  dialogs, IME, and accessibility.
- Lost: Slint's styling, declarative bindings, and compiled-UI embedding. The
  designer's selection layer must paint over native children (`wxOverlay`).
- The component model stays target-neutral so a web/HTML renderer remains
  possible; only the wx adapter is built now.
