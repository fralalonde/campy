# ADR 0003: zgui replaces Slint as the native UI engine

Status: accepted for the zgui migration branch (`zgui-migration`).

## Context

Campy rendered through Slint's interpreter (pinned `=1.18.1` for its
`with_any_thread` winit backend). The evaluation in `bench/` measured the
alternatives against campy's own bridge operations; zgui 0.1.0 matched
campy's architecture (an imperative document seam with public
implementations, a headless platform backend, runtime-installable
stylesheets, virtualization) and its pipeline costs (sparse ≈ 92 µs,
view rebuild ≈ 14 ms, no interpreter compile step) while the Slint path
paid ≈ 44 ms per `LoadUi` compile plus a full-window CPU raster.

## Decisions

1. **One zgui application per OS process, one window per bridge session.**
   The NIF starts a dedicated UI thread that owns a zgui `Runtime` and a
   winit event loop. Campy builds the loop itself —
   `EventLoop::with_user_event().with_any_thread(true)` driving zgui's
   public `WinitApp` — so **no zgui fork is required** (the loop-splitting
   embedder API at `zgui_platform_winit::WinitApp` is public). Wayland and
   X11 both ride this path; zgui's own Wayland backend remains a future
   alternative. macOS NIF embedding stays unsupported, as before.
2. **Wire protocol v2 (documented in `docs/PHASE2.md` §1.4).** UI-as-data
   survives: `LoadUi(generation, title, size, theme, controls)` carries a
   control tree (`ControlDesc`), and granular ops (`SetText`, `SetBool`,
   `SetInt`, `SetFloat`, `SetModel`, `SetGeometry`, `SetCode`,
   `AppendConsole`, `ReadText`, `Resize`) address controls by id. The
   event envelope is unchanged (`session, generation, kind, payload`);
   kinds become `control:<id>:<event>`, `pointer:<id>:<phase>`,
   `editor:<id>:changed`, `read:<id>:<key>`. Protocol version 2.
3. **The description is the reload unit.** `LoadUi` sets the window's
   description signal; zgui's incremental rebuild applies it (measured
   ~14 ms for a 64-control form). No interpreter, no per-load compile, no
   8 MiB compiler stack. Failed candidates are rejected before the signal
   write (validate-on-BEAM first), preserving campy's reload boundary.
4. **CCL aligns to the zgui widget model.** Kinds map: label→`text`,
   edit→zgui-ui `Input`, memo→`editor`, button→`Button`, checkbox→
   `Checkbox`, radio→`Checkbox`(radio role), combo→`Combobox`/`Select`,
   list→`VirtualList`, slider→`Slider`, progress→`Progress`, picture→
   `image`, panel/group→`box`, plus new campy kinds `code_editor` (zgui-
   editor with the Gleam tree-sitter grammar) and `console` (zgui-terminal
   over a BEAM-fed `Transport`). No project backward compatibility: only
   the Cat Café demo exists and it is regenerated.
5. **The IDE shell and designed forms share the same protocol** (the
   dogfood rule). The shell is a `ControlDesc` tree loaded once; the
   designer canvas is a `surface` kind that forwards raw pointer phases
   (Gleam keeps hit-testing, which is renderer-agnostic today). The
   ultimate dogfood: a generated project whose modules reference campy's
   own Gleam sources externally (project codec v12: external-source
   modules), edited inside campy with the zgui-editor + Gleam LS.
6. **Dependencies.** zgui stack via git, pinned to one rev, verified by
   building zgui-editor and zgui-terminal against it (they are not on
   crates.io). The umbrella's optional features stay off (`tokio`,
   `instrument`). Removed: `slint`, `slint-interpreter`, `spin_on`, `png`
   (snapshots become headless scene transcripts). Added:
   `zgui`/`zgui-ui`/`zgui-editor`/`zgui-terminal` (git, pinned),
   `tree-sitter-gleam`. New GPU footprint (wgpu/Vello) is accepted:
   packaging bundles the native GPU libraries alongside the existing X11
   set.
7. **Testing moves headless-first.** The same `Runtime` runs under
   `zgui-platform-headless` in the smoke suite (scripted `SurfaceEvent`s,
   virtual clock, scene transcripts) — replacing the Slint
   `dispatch_event` injection, which zgui's winit path has no equivalent
   of. A display is no longer required for the automated smoke test.

## Platform findings (recorded so nobody relearns them)

1. **Scripted input needs monotonic timestamps.** Under
   `zgui-platform-headless`, surface events stamped with a stale
   `Timestamp::ORIGIN` can silently stop being recognized as clicks once
   the virtual clock has advanced; the driver stamps each event relative
   to the accumulated clock.
2. **zgui-ui components are unverified through surface input.** Their own
   tests dispatch through the component testkit, not the platform
   pipeline. In our headless harness a styled base `control` with
   `on:click` fires reliably while a zgui-ui `Button` did not; campy's
   interactive controls therefore render as campy-styled base elements,
   and zgui-ui components get a live-window A/B at gate G1 before the IDE
   shell adopts any of them (and an upstream issue if it reproduces).

## Consequences

- F6 keeps its BEAM semantics (module swap on the VM, unchanged
  `campy_hot_ffi`) and its native half becomes a `LoadUi` of the newly
  generated description — faster and simpler than the compile-and-swap
  interpreter path it replaces.
- Rust-side changes still need a process restart (as today).
- We accept zgui 0.x churn: the pin is one rev, upgrades are deliberate,
  and `bench/bench-zgui` + the headless smoke detect behavioral drift.
- Slint leaves the tree on this branch (`archive/slint-ui` keeps it).
