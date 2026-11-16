# ADR 0004: view tree, patches, projection, and ABI v2

Status: accepted.

## Context

Campy is becoming an IDDDE for BEAM clusters: the IDE authors and builds, a
broker versions and stores artifacts, and runner nodes host apps. Servers
usually have no display, and a cluster may have several clients (the IDE, a
browser later, a remote operator). The Slint prototype assumed a window inside
the app's own VM and a NIF channel to it; that assumption cannot survive
distribution.

The prototype also has no state: handlers are zero-argument functions returning
`Nil`, and an app's state is only its form snapshot. Deploy and debug are hollow
without application state.

## Decision

### 1. An app is state plus handlers; the view is a function of state

```gleam
pub type State // application-defined

pub fn init() -> State
pub fn view(state: State) -> campy_form.Form
pub fn <control>_<event>(state: State, event: Event) -> #(State, List(Effect))
pub const state_version: Int
pub fn migrate(state: State, from: Int) -> State // optional
```

- Event dispatch resolves the handler name from the form (`control_name` plus
  event key), checks `function_exported(Mod, Fun, 2)`, and calls it. A missing
  handler is a no-op; a raising handler is a contained `HandlerError` report,
  never a restart.
- `Event` carries the control, the event key, the control's value, and the view
  generation. `Effect` is deliberately small: `Log`, `Notify`, `Stop`.
- State is opaque to the runtime, inspectable through `:sys.get_state`, and
  upgraded through `migrate` using the manifest's migration chain.

### 2. The view is data; clients diff and render

The runtime derives the view from state after each event. It sends the whole
form document with a generation; the client diffs against what it has.
Documents are small (forms are tens of controls), and this keeps nodes
headless, dumb, and cheap. Diffing is a client concern.

```
Attach(client, generation)          client -> runner
View(generation, node)              runner -> client, on change
Event(generation, id, key, value)   client -> runner
```

- Stale generations are discarded by the client and ignored by the runner.
- The same terms travel as plain Erlang messages between nodes; JSON mapping is
  a later transport concern, not part of the model.
- The wire protocol carries documents, so no renderer-specific instructions
  exist in the runtime.

### 3. Peers are nodes, not ports

Local runner nodes are started with `:peer` and connected by distribution, not
by a child-process protocol. Deploy sends the manifest and beams as binaries and
loads them with `code:load_binary`; `campy_control` exposes
`deploy/start/stop/status/state/trace`. Events and reports use plain `send`.
The IDE is a hidden node. This makes "remote later" a placement change rather
than a rewrite, and it retires the planned port framing work.

### 4. The IDE is a client too

`campy_ide` holds authoring state and is display-free; `campy_ide_wx` owns the
wx shell and speaks the view protocol like any other client. The designer uses
the same renderer in design mode. This is what makes the IDE testable headlessly
and keeps the shell replaceable.

## Consequences

- The bridge command queue, ownership checks, session handles, and polling loop
  are gone. Messages and generations replace them.
- Apps can hold real state, which is what deploy and debug need.
- Handler ABI v1 projects are migrated by codegen: zero-argument stubs become
  `(state, event)` handlers, and `init`/`view` wrappers are generated.
- Live updates are diffs, so focus, selection, and scroll survive state changes.
- A buggy `view` re-sends a large document; the client diff makes it cheap, but
  the actor should only send when the derived view actually differs.
- Distribution authority is real: the IDE joins with a cookie and can call
  anything. `campy_control` is the intended surface; raw `:rpc` from UI code is
  avoided, and non-loopback clusters require TLS distribution or a tunnel.
