# Runtime architecture

## Ownership and rendering

Each application process contains BEAM and the Rustler NIF. Gleam owns application
state, document editing, and event handling. A dedicated Rust UI thread owns one
zgui application and its winit event loop, with one window per bridge session.
Linux and Windows support this embedding; macOS startup is not implemented.

The IDE uses the same control descriptions and bridge operations as its previews.
The renderer uses zgui, wgpu and Vello, with zgui-editor for source editing and
zgui-terminal for console output. There is no Slint interpreter or per-load UI
compilation in the native runtime. See [ADR 0003](adr/0003-zgui-migration.md) for
the migration rationale and [phase 2](PHASE2.md) for implementation history.

## Protocol and data flow

The protocol-v2 contract is mirrored by `campy_bridge.gleam`, Rust `wire.rs`, and
the Rustler decoder in `campy-bridge/src/lib.rs`:

1. The owning BEAM process opens a session and submits a `LoadUi` document: title,
   size, theme, generation, and a tree of `ControlDesc` records with stable IDs.
2. Short NIF calls decode and validate commands, then enqueue owned data on a
   bounded queue. Enqueue success is distinct from UI-thread completion.
3. A reactive wake signal drains commands on the UI thread. Idle windows do not
   poll for commands. A platform event-loop proxy also wakes the native loop.
4. The renderer reconciles descriptions by control ID, retaining unchanged nodes
   and signals. Granular text, geometry, model, code, console, and mark operations
   update existing controls. A `Batch` groups related changes into one submission.
5. Native events return to the owner as `(session, generation, kind, payload)`.
   `ui-loaded`, `command-failed`, `closed`, and `runtime-failed` report lifecycle
   outcomes; control/editor/pointer events carry input; `read:` replies serve as
   completion barriers.

`LoadUi` must increase the generation; other operations must match the accepted
generation. Loads cannot be batched. The NIF checks session ownership, and cleanup
uses atomic flags so a full queue cannot prevent closing a session. UI handles
stay on the UI thread. A native crash can still affect the whole VM.

## IDE and project state

`campy_form` represents designed controls, geometry, container layout, properties,
and project/workspace persistence. `campy_ccl` defines the component catalog.
Project files are versioned; supported older versions are migrated explicitly.
External-source modules reference Gleam files rather than storing their contents
inside the project.

`campy_ide/state` reduces user actions and keeps undo/redo history. A pointer
movement updates the active gesture; a completed drag records one undo step.
`campy_ide/shell` builds the control tree, while `campy_ide/ide_ui` derives the
operations needed to reconcile successive state snapshots. The designer renders
controls passively inside a pointer surface so Gleam can manage selection,
marquees, placement, movement, and resizing.

Preview windows are tracked per module and use `campy_form/live_preview` to build
the same protocol-v2 descriptions. F7 updates a running preview. Preview events
are logged; preview windows do not execute user handler code. The broker/app
packages provide an experimental generation and build path, separate from the
IDE's visual preview.

## Development and reload boundaries

- `just dev` watches source trees and manifests across workspace packages. It
  rebuilds on edits, additions, and deletions, then restarts the IDE only when
  compilation succeeds. A failed build leaves the running IDE in place.
- F6 reloads Gleam modules in the running VM and rebuilds the shell description.
  A project-format change reloads the workspace. Other incompatible state-shape
  changes and Rust/NIF changes require a restart.
- `just smoke-reload` exercises the narrower search-box definition reload in one
  VM: successful updates, rejected definitions/builds, and recovery. This is not
  a transactional upgrade of arbitrary application state.

BEAM module replacement is not a global transaction. Code and state compatibility
must be handled explicitly; full migration/effect coordination remains roadmap
work. See [ADR 0002](adr/0002-three-role-architecture.md).

## Package boundaries

| Package | Responsibility |
| --- | --- |
| `campy_ccl`, `campy_form` | Component catalog, forms, projects, workspaces, preview descriptions |
| `campy_bridge` | Gleam wire types and native externals |
| `campy-bridge` | Rustler decoding, session ownership, events, language-server transport |
| `campy-renderer` | zgui controls, reconciliation, UI-thread lifecycle and headless driver |
| `campy_ide` | Studio state, shell, editor integration and preview orchestration |
| `campy_manifest`, `campy_app`, `campy_appgen` | Artifact contracts, application handling and generated source |
| `campy_broker`, `campy_runner` | Experimental build/artifact and deployment/routing workflows |
| `campy_ui`, `campy_runtime`, `campy_search_box` | Original definition/model/reload fixture |

The last group still includes legacy Slint text emitters used by fixture tests
and `just generate`. That output is not loaded by the current native renderer.
The comparison programs in `bench/` are likewise separate from the production
Rust workspace; retaining Slint there supports historical comparisons.

## Build and verification

The native stack ships as one platform library (`campy_bridge.dll` on Windows,
`campy_bridge.so` on Linux) staged under the Gleam bridge's `priv/native` directory.
Cargo lockfiles pin git dependencies, and build recipes use `--locked`. Release
builds strip symbols and use fat LTO; development builds keep line-table debug
information. `just package` stages the release NIF, exports an Erlang shipment,
checks its NIF handshake, and bundles available native dependencies.

`just check` runs formatting, Clippy, Python runner regressions, Rust tests and
Gleam tests. The Rust integration test uses zgui's headless platform to exercise
input and session behavior without a display. `just smoke-native` checks the
same path through the BEAM/NIF boundary and stages a test NIF; `just build`
restores the normal native build.

`just smoke` checks the original definition pipeline and protocol handshake.
`just snapshot-ide` verifies state transitions against a live renderer using
read barriers; its historical name does not imply PNG output. Live window tests
are opt-in (`just test-live`). Headless tests do not verify GPU output or native
operating-system input; those require a desktop session.
