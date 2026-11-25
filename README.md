# Campy

![Campy Studio](docs/images/campy-studio.png)

**Idea:** A native, Gleam-first RAD studio. Design forms, edit properties and handlers, and run the result in a live window. The IDE uses the same component model and runtime as the apps it builds.

**Why:** Keep application state and behavior on the BEAM; use zgui for native rendering. A Rust NIF owns the UI thread and passes events to Gleam. Forms update through control descriptions and granular commands without rebuilding the bridge.

## Requirements

- Rust 1.92+, Gleam 1.16+, Erlang/OTP 27+, Python 3, `just`, Bash.
- Linux: Wayland or X11 and Winit runtime libraries; X11 also needs `libxkbcommon-x11`.
- Windows: Git Bash on `PATH`. macOS startup is not implemented.
- Network access for the first dependency build.

## Install and run

```sh
git clone https://github.com/fralalonde/campy.git
cd campy
just doctor
just run
```

`just run` builds Rust and Gleam, stages the NIF, and opens Campy Studio. On Linux, `./campy` is an equivalent launcher. `just dev` watches all workspace package sources and manifests, including added or removed files, and rebuilds/restarts the IDE after successful changes. `just clean` removes Rust/Gleam build artifacts and the staged development NIF.

## Checks

- `just check`: formatting, Clippy, Python runner regressions, Rust headless tests, and Gleam tests.
- `just smoke`: display-free definition validation and NIF protocol handshake.
- `just smoke-native`: native NIF input, resize, generation, ownership, and lifecycle checks using zgui's headless platform. It does not open a window or capture a PNG.
- `just smoke-reload`: description reload success, rejection, and recovery in one BEAM VM; temporarily edits and restores the search-box fixture.
- `just snapshot-ide`: verifies IDE state transitions against a live window; despite the historical name, it does not write snapshots.

`smoke-native` stages a test NIF; `just build` restores the normal development NIF. Source and text fixtures use LF on all platforms, enforced by `.gitattributes`.

## Package for distribution

```sh
just package
```

Produces `generated/dist/campy-studio-<version>-<os>-<arch>.tar.gz`: a portable
build that unpacks anywhere and runs with `./campy`, requiring only an
Erlang/OTP 27+ installation (`erl` on PATH) — no Rust, Gleam, Python, or
`just`. The release NIF and the windowing stack's native libraries
(`libxkbcommon-x11` and friends, from `generated/native-deps`) are bundled.

## State and limits

- Working prototype: project/workspace persistence, form designer, property inspector, undo/redo, native preview, and F7 updates to a running form.
- Handler stubs can be edited, but the preview does not execute handler code. Its console logs events and input.
- F6 reloads Gleam code in the IDE (a project-format upgrade reloads the workspace in place); Rust/NIF changes and other state-shape changes need a restart.
- `just build-app` is experimental: it compiles one module of `campy.campy` (default: `widgets`) into a versioned artifact under `generated/broker/artifacts/`, printing the manifest summary line and the artifact path. It exercises generation and compilation only; the artifact is not dispatched or run.
- Palette drag-and-drop, richer source editing, and the general versioned component schema are unfinished.
- Native sessions run on Linux and Windows. Headless checks do not verify GPU rendering or operating-system input integration.

Architecture and roadmap: [current architecture](docs/ARCHITECTURE.md) · [phase 2](docs/PHASE2.md) · [historical MVP](docs/MVP.md).
