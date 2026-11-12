# ADR 0001: dedicated Linux Winit UI thread

Status: accepted for the M0 Linux prototype.

## Decision

Run the Slint Winit backend and every live Slint component on one dedicated Rust
thread inside the BEAM OS process. Use the public Slint backend selector with
`winit` and `software`. No patched OTP launcher, IPC renderer, embedded BEAM
library, or browser is needed for the verified Linux path.

Slint's generic guidance says the main thread is required by most backends. The
pinned Winit backend is more specific: version 1.18.1 configures both its Linux
Wayland and X11 builders with `with_any_thread(true)`. The adapter relies on that
implementation and pins its Slint version. The original M0 adapter refused native
sessions on other OSes.
See [the backend source](https://github.com/slint-ui/slint/blob/v1.18.1/internal/backends/winit/lib.rs).

## Windows follow-up

The same pinned backend also sets `with_any_thread(true)` for Windows. Campy now
allows Windows native sessions and keeps its `/proc/thread-self` assertion on
Linux only. The Windows `just smoke-native` run verified a real window, synthetic
main-window input, snapshot, resize, reload, generations, ownership, and cleanup.
The Windows `just run` path opened the IDE and reached UI generation 1. The smoke
adapter does not cover Windows context-menu popup input.

## Ownership and scheduling

- BEAM callers create monitored session resources owned by the calling actor.
- Resources contain thread-safe IDs, atomic cleanup state, and a queue endpoint.
- A bounded queue holds at most 64 commands; at most 32 sessions may be registered.
- Short NIF calls enqueue commands. Completion/errors arrive as mailbox events.
- An 8 ms UI-thread timer drains at most 8 commands per iteration. Cleanup uses
  atomic flags, so a full command queue cannot prevent owner-death cleanup.
- All creation, mutation, snapshot, hiding, and destruction of live Slint values
  occur on the UI thread. No `ComponentInstance` crosses a scheduler boundary.
- An explicit 8 MiB stack accommodates Slint compiler recursion. Headless validation
  uses a separate native compiler worker and a waiting dirty I/O NIF.
- `run_event_loop_until_quit` keeps the one event loop available between sessions.
  The UI thread lasts for the VM's lifetime. Hot replacement of the NIF is unsupported.

Native callbacks currently support the MVP's string payload or no payload. The
mailbox transport is not yet a bounded/coalescing event protocol; that is M2 work.
UI compilation happens on the UI thread and can pause native interaction briefly.

## Reload boundary

Load and validate a replacement interpreted window before hiding the previous one.
Copy matching public properties and window dimensions to the candidate. Only
successful replacement advances its generation. Reject commands from stale
generations. This preserves the query for the current search-box contract.

The Gleam host commits its candidate description after receiving `ui-loaded`.
BEAM module replacement is still the limited stable-ABI development mechanism;
there is no general code/state/effect rollback transaction.

## Verification

The native smoke test opens real Wayland/X11 windows with the software renderer.
It verifies Slint control input/callbacks, requested OS-window resizing and a
640×140 rendered snapshot, property-preserving reload, failed candidate retention,
stale command rejection, actor ownership, explicit/native close, and owner-death
cleanup while another BEAM process continues its heartbeat.

Input is dispatched through Slint's public window-event API using the `ui-testing`
Cargo feature. It does not depend on desktop focus or send input to other apps.
The feature is absent from ordinary `just run` builds. This verifies control input
handling, not the compositor's physical keyboard/IME integration.

Wayland startup and live BEAM heartbeat were also exercised through `just run`.
The X11 container lacked `libxkbcommon-x11`; an RPM was downloaded and extracted
under ignored `generated/native-deps/` without installing system packages. The
runner supports that local library path. Fresh environments should supply their
distribution's native Winit dependencies.

## Limits

macOS startup needs a separate decision and verification. Focus,
selection, scroll, IME composition preservation, generic schemas, package loading,
and robust state/effect migration remain later milestones.

