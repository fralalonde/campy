# Campy

A native, Gleam-first RAD environment. The IDE and its applications will use the
same component packages, BEAM runtime, and in-process Rust/Slint bridge.

## Status

`just run` opens **Campy Studio**, a Delphi/Lazarus-style IDE built from the same
interpreted Slint runtime and the same **CCL** component catalog as the apps it
designs. Campy opens **its own workspace** (`projects/workspace.campy`, created
on first run) containing its own project (`projects/campy.campy`), whose modules
are the **Cat Café** and **CCL Widgets** demos.

Layout:

- **Left — workspace navigator**: a workspace manager (switch, create, and delete
  projects) above a `ListView` of the active project's modules; click a module
  to open or activate it, `+` to add one.
- **Centre — tabbed module editor**: one tab per opened module (with a close
  button). The single top-right button switches between the **form editor** and
  the module's **handler code**. The form editor has bottom **UI (actual)** and
  **Code (Slint file)** tabs; the latter shows the generated, read-only Slint
  source for the form.
- **Right — components + inspector**: the component palette is a `ListView` of
  the CCL catalog (Label, Edit, Memo, Button, Check box, Radio button, Combo
  box, List, Slider, Progress, Panel, Group box, Picture), and the object
  inspector shares the pane.
- **Form canvas**: drag a control to move it and use any of the **eight resize
  handles** (four corners and four sides) to resize it. The UI tracks the gesture
  locally and commits once on release; corners/edges resize both geometry and
  origin as needed, with directional cursors. Click the empty canvas to select
  the **window** itself. The form can use **Free**, **Column**, or **Row**
  layout; Column/Row use Slint layouts, so resizing the window reflows the
  controls without sending any geometry messages. In the Free designer the
  form is a **module window** with a title bar: drag the bar to move it and the
  corner handle to resize the form. Window positions are kept per module. Free controls can also use
  LCL-style **alignment** (Top, Bottom, Left, Right, Client), which binds their
  geometry to the form's Slint layout.
- **Adoption and clipboard**: panels and group boxes accept children. New and
  pasted controls are adopted by the selected container, its first accepting
  ancestor, or the window; **dragging a control onto a panel reparents it**, and
  dragging it out returns it to the window. Nested panels work, children draw
  above their container, and moving a panel moves its children with it. Edit →
  Copy / Cut / Paste works on whole subtrees.
- **Workspace**: several independent projects can be open at once. Switching,
  creating, and deleting projects is done in the left manager. The workspace and
  every project edit are persisted automatically in
  `projects/workspace.campy`; deleting a project only removes it from the
  workspace, not its file.
- **Undo/Redo**: every form, inspector, module-creation, and handler edit is
  recorded in one global history. Use Edit → Undo/Redo, the ↶ / ↷ toolbar
  buttons, or Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y.
- **Delete**: the small trashcan next to the selected component's name, the Edit
  menu, or the Delete key removes the control (and its subtree).
- **System dialogs**: Open, Save As, and the Picture picker use the desktop file
  dialog through Zenity or KDialog when available; the in-window path dialog is
  the portable fallback.
- **Hot reload (F6)**: press F6 while Campy is running to rebuild the Gleam
  app, hot-load the new Beams into the same BEAM VM, and reload the Slint shell
  with the new `ide_ui` source. State/models are re-applied after the refresh, so
  the IDE process, workspace, and project state survive. Rust/NIF changes and
  state-shape changes still need a restart.
- **Live app (F7)**: Run opens the app under development in a live, model-driven
  preview. While it is running, **F7** pushes the current module's form (title,
  size, layout, controls, pictures, alignment) into the same window — no reload
  or second window. The generated Slint tab still shows the static source.
- **Keyboard shortcuts**: Ctrl+N / Ctrl+Shift+N (new project/module), Ctrl+O,
  Ctrl+S, Ctrl+Shift+S, Ctrl+Q, Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, Ctrl+C / Ctrl+X /
  Ctrl+V, Delete, F5, **F6** (reload Campy code), **F7** (update running app),
  Shift+F5, and Escape. Text
  fields keep their own editing shortcuts; otherwise the bindings act on the
  designer.
- **Console**: the form editor's **Console** tab shows the running app's
  lifecycle/events and accepts stdin lines. The current preview logs input but
  does not execute handler code yet, so stdin is reserved for the app runtime.
- **Settings — Editor… / Agent…**: the Editor page sets font family, font size,
  color scheme and UI hints. The Agent page enables the optional **MCP server**
  (disabled by default), edits its localhost port, and shows the endpoint
  (`http://127.0.0.1:<port>/mcp`).
- **Top — menus**: File, Edit (undo/redo and copy/cut/paste/delete), Run, and
  Settings, plus ↶ / ↷, ▶ Run, and ■ Stop.

The window is resizable and maximizable (preferred size, not a fixed size), and
primary actions use the accent color with pictograms. Labels are drawn without a
designer outline unless selected.

The inspector edits the canonical form model (name, text, x, y, w, h, enabled,
visible), and the Events tab (`OnClick`, `OnTextChanged`) opens the handler in
the central Code view, generating a typed Gleam stub when one does not exist.
The Code view is syntax-highlighted and has a focused editor for the selected
handler with Apply/Cancel. Files are versioned Erlang-term projects (v5);
v1–v4 files are upgraded on load. The Cat Café demo demonstrates a panel with
adopted children, a picture, a list, and handler stubs; the Widgets module
showcases the CCL controls and top/bottom aligned labels.

The **CCL** catalog lives in its own dependency-free `campy_ccl` package and is
the shared source of component keys, labels, default sizes, events, and
palette rows for both the designer and the IDE. The project model, handler
stubs, project and workspace codecs, and both Slint emitters live in the
`campy_form` package. The IDE shell itself is generated by
`campy_ide/ide_ui` from the project state, so panels are data-driven and every
interaction is a typed callback on the existing generic bridge. The shell is
generated **once at startup and not reloaded by ordinary edits** (F6 explicitly
refreshes it): navigator rows, module tabs,
canvas controls, and code tokens are Slint models rendered by `for` loops, and
everything else is scalar root properties. Selecting controls, editing values,
switching tabs/views, adding or deleting controls, opening modules, applying
handler code, loading projects, undo/redo, Run/Stop, and dialogs are all applied
in place with `SetText`/`SetBool`/`SetInt`/`SetColor`/`SetModel` (models can carry
images and structs). The form model does not yet include menu/tab/tree/text-edit
primitives, so the IDE's own chrome is generated rather than being a module you
can edit in the designer.

Still later milestones from [MVP.md](docs/MVP.md): the general versioned
component schema (M1), model batches and full event semantics (M2), package
loading/hot reload (M3), and the remaining designer work (drag-and-drop from the
palette, richer code editing, source-aware hand edits). The M0 native search-box host, its smoke
tests, and `campy_search_box` remain as the original runtime spike.

## Quick start

Prerequisites: Rust/Cargo (Rust 1.92+), Gleam 1.16+, Erlang/OTP 27+, Python 3,
and `just`. Cargo builds go through `scripts/cargo.sh`, which selects the
project's compatible toolchain when installed (the system clang/mold toolchain
can produce a NIF requiring a newer glibc than the runtime provides). Native execution requires a working Wayland or X11 display and the
Winit runtime libraries. X11 needs `libxkbcommon-x11` in addition to the usual X11
and keyboard libraries. The lockfiles record the resolved dependency graph. Slint is pinned
to 1.18.1 and Rustler to 0.39.0. First builds need network access.

```sh
cd ~/Code/Campy
just doctor
just run              # open Campy Studio; close the window to exit
just dev              # IDE plus restart-on-save source watching
just check            # formatting + display-free Rust/Gleam/NIF tests
just snapshot-ide     # render IDE/handler/form PNGs into generated/
just smoke            # display-free compiler bootstrap
just generate         # inspect derived Slint for the search-box demo
just smoke-reload     # headless stable-ABI code reload test
just smoke-native     # native rendering/input/lifecycle test
just smoke-native x11 # exercise X11 explicitly
```

`just run` builds both languages, stages the NIF, and opens the IDE. Use
**File** to create, open, save, or save-as a project (default
`projects/campy.campy`), and **Run** to open the designed form in a second native
window. While it runs, press **F7** to apply your edits to that same window. A periodic BEAM heartbeat demonstrates that the native event
loop does not block BEAM scheduling.

`just dev` watches the IDE and `campy_form` sources; a successful `gleam build`
restarts the IDE window with the new code (Rust is untouched). Failed builds keep
the running IDE.

`just snapshot-ide` writes `generated/ide-smoke.png` (workspace + navigator + Cat
Café form), `ide-widgets.png` (the CCL Widgets module), `ide-code.png`
(highlighted source), `ide-edit.png` (handler stub opened from the inspector),
`ide-open.png` (file dialog), `ide-settings.png` (editor font/scheme dialog),
`ide-slint.png` (generated Slint tab), `ide-light.png` (light color scheme),
`ide-form.png` (the static generated preview), `app-live.png` and
`app-updated.png` (the live app before/after an F7-style update in the same
window), `ide-updated.png` (selection applied through properties only),
`ide-multiselect.png`, `ide-drop-target.png`, `ide-place.png`,
`ide-select-mode.png`, `ide-console.png`, `ide-agent.png`, and
`ide-workspace.png` for visual review. `just generate` writes the derived
`generated/search_box.slint` fixture; do not edit it. `just fmt` formats both
languages. `just check` runs the display-free test suite, including real NIF
integration.

The native smoke test uses actual windows and a test-only Slint input adapter;
it does not inject desktop-wide keyboard or pointer input. It verifies resize,
reload with nonempty query, stale generations, ownership, close, and owner death,
then saves `generated/native-smoke.png`. A working display is required.

See [ADR 0001](docs/adr/0001-linux-ui-thread.md) for the Linux thread decision,
verification details, native dependencies, and remaining limits.

## Project layout

```text
Campy/
  justfile                         cross-toolchain commands
  docs/
    MVP.md                         milestones and acceptance criteria
    ARCHITECTURE.md                ownership, bindings, reload protocol
    COMPONENT_API.md               current API and intended public API
  rust/
    Cargo.toml                     Cargo workspace
    crates/
      campy-bridge/                 Rustler cdylib; the BEAM boundary
      campy-renderer/               Slint interpreter and Linux UI-thread owner
  gleam/
    packages/
      campy_ui/                    canonical description, validation, Slint emitter
      campy_ccl/                   CCL component catalog shared by designer and IDE
      campy_form/                  designer model, handler stubs, project/workspace codecs, preview
      campy_bridge/                typed externals and tiny Erlang NIF loader
      campy_runtime/               component identity and generation management
      campy_search_box/            first portable, all-Gleam component package
    apps/
      campy_ide/                   Campy Studio: IDE shell, event loop, snapshots
  scripts/workspace.py             build, staging, and development watcher
  generated/                      ignored derived artifacts
```

Each Gleam package has its own `gleam.toml` and path dependencies; `gleam/` is a
subroot, not a fictional Gleam workspace. The runner executes commands in each
package. No application behavior belongs in Rust. No component package depends
on a component-specific Rust crate.

## Decisions to preserve

- Declarative Gleam descriptions are authoritative; Slint, the run window, and
  the IDE shell are derived artifacts. The designer edits a form model today;
  source-aware editing of the declarative Gleam subset is M4 work.
- The native bridge is generic. Loading ordinary components must not rebuild it.
- One Slint event loop per OS process, with logical sessions owned by BEAM actors.
- Continuous interaction stays on the UI thread; BEAM owns durable application state.
- UI reload and code reload are separate operations coordinated by the runtime.
- Runtime compilation remains available in released applications that load plugins.
- Desktop Linux is the first implementation target. macOS and Windows require
  explicit startup validation before being advertised as supported.

See [the MVP plan](docs/MVP.md) for the next implementation steps.

