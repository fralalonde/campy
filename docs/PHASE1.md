# Phase 1 — Compilable apps, local broker/runner (OTP seams)

This is a dispatch plan. Every task below is a self-contained brief: a fresh agent
with no prior conversation context can execute it given only §1 (Shared context)
and the brief itself. Tasks are sized so each is one agent session. Expensive
review is batched at gates G0–G3 (§5) instead of per task.

Goal of the phase, in one sentence: **a designed app becomes a compilable,
supervised OTP application with a versioned artifact and migration chain; Run /
F7 / Stop flow through local broker and runner seams; the developer sees no new
concepts.**

Non-goals for this phase (do not build, do not stub beyond what briefs say):
iroh transport, artifact signing/verification, broker federation, remote
runners, web/CLI management UIs, app persistent-state migrations, config
tracking, metrics. All are recorded as future work in ADR 0002.

## 1. Shared context (paste this section into every dispatch prompt)

### 1.1 What Campy is today

Campy is a Gleam-first RAD studio (IDE) in one OS process: BEAM + a Rust NIF
(`campy-bridge`, `campy-renderer`) owning a Slint UI thread. Key facts:

- The IDE is a Gleam application using the same runtime it designs for.
- Projects are versioned compressed Erlang terms (project codec v9, workspace
  v1) stored under `projects/`. A project holds modules; each module has one
  form + handler source.
- "Run" opens a **second bridge session in the same VM** (a preview window).
  F7 re-applies the active module's form snapshot to that session. The preview
  does **not** execute handler code today.
- Handlers are zero-arg Gleam functions: `pub fn <control>_<event>() -> Nil`.
  Names are derived, never stored (`campy_form.handler_name`).
- F6 rebuilds the IDE itself (`campy_hot_ffi.erl`): spawns `gleam build` via a
  port, hot-loads the resulting beams. This port pattern is the model for the
  broker's build step.
- One process polls native events (`campy_bridge_ffi:poll`) and routes them by
  session id — the IDE loop in `campy_ide.gleam`. **Never introduce a second
  poller in the same VM.**
- MCP server (optional, localhost) forwards tool calls into the IDE loop.

### 1.2 Where this phase comes from (architecture summary)

Three roles, currently de facto, becoming explicit seams — all local, all
in-process in this phase except P1.3:

- **IDE** — authors projects, compiles artifacts (with future help for
  cross-native builds), pushes to broker, selects runner targets.
- **Broker** — verifies, versions, stores artifacts; tracks deployment state;
  dispatches to runners. Toolchain-free: it never compiles (the IDE pushes
  built artifacts). Its authority is manifest/contract verification.
- **Runner** — hosts apps as supervised OTP applications; pulls/applies
  updates; never sees source (workflow boundary, not security); runs detached
  when the broker is gone; reports apply results and health.

OTP alignment is the guiding principle ("stand on giants"): apps are
`gleam_otp`-supervised; updates follow the appup pattern (prepare → validate →
migrate → pause → commit → resume → retire, old generation retained until
commit); migration knowledge ships as data in the artifact, executed
mechanically by the runner; failed updates leave the running app untouched and
report back. See `docs/ARCHITECTURE.md` (reload protocol) and `docs/MVP.md`
(M1–M3) for the doctrinal background.

### 1.3 Codebase map

| Path | What it is |
| --- | --- |
| `gleam/apps/campy_ide/src/campy_ide.gleam` | IDE loop, dispatch, `run_form`/`update_app`/`stop_form`, MCP handling, event routing |
| `gleam/apps/campy_ide/src/campy_ide/state.gleam` | IDE `State`, `Preview` record, console, undo history, format migration (`ensure_current_format`) |
| `gleam/apps/campy_ide/src/campy_ide/live_preview_ui.gleam` | Applies a live-preview snapshot to a bridge session (property/model commands) |
| `gleam/apps/campy_ide/src/campy_ide/mcp.gleam` | MCP client surface (tools list/call) |
| `gleam/apps/campy_ide/src/campy_hot_ffi.erl` | Port-spawn `gleam build` (180 s timeout) + soft-purge module reload. **Reuse this pattern.** |
| `gleam/packages/campy_form/src/campy_form.gleam` | Form model, `handler_name`, `ensure_handler`, `validate`, geometry |
| `gleam/packages/campy_form/src/campy_form/project.gleam` | Project codec v9 (versioned compressed term save/load) — **the codec pattern to copy** |
| `gleam/packages/campy_form/src/campy_form/workspace.gleam` | Workspace codec v1 |
| `gleam/packages/campy_form/src/campy_form/live_preview.gleam` | Emits the preview shell Slint + snapshot type (`to_slint`, `snapshot`) |
| `gleam/packages/campy_bridge/src/campy_bridge.gleam` | `Session`, `Command` (`LoadUi/SetText/SetModel/…`), `WireValue`, `poll` |
| `gleam/packages/campy_runtime/src/campy_runtime.gleam` | Session/generation abstraction (32 lines; grows later, not in this phase) |
| `gleam/packages/campy_ccl/` | Dependency-free component catalog (keys, labels, events) |
| `rust/crates/campy-bridge`, `rust/crates/campy-renderer` | NIF + Slint renderer. **No Rust changes in P1.0–P1.2.** |
| `scripts/workspace.py` | Build orchestration: stage NIF, run IDE, export erlang-shipment |
| `justfile` | `just check` = fmt-check + test; `just build`, `just run`, `just package` |

### 1.4 Conventions and guardrails (apply to every task)

1. **Gleam only** in P1.0–P1.2 (Erlang `.erl` FFI files inside `src/` are fine
   and follow `campy_hot_ffi.erl`'s style). No Rust changes. P1.3 touches only
   `scripts/workspace.py` plus new Gleam files.
2. New packages go to `gleam/packages/<name>/` with `gleam.toml`
   (`target = "erlang"`, `gleam = ">= 1.16.0 and < 2.0.0"`, gleeunit
   dev-dependency, path deps to other campy packages). Runnable apps go to
   `gleam/apps/`. **A brief that creates a package must also add its name to
   the `PACKAGES` tuple in `scripts/workspace.py`** (one line) so `just check`
   builds and tests it; this registration is part of the brief's Files list.
3. Dependency rules (from `docs/ARCHITECTURE.md`): `campy_bridge` is the sole
   owner of native externals; `campy_form`/`campy_ccl` stay pure (no bridge
   dependency); app-level packages may depend on the bridge.
4. On-disk versioned documents use the `campy_form/project.gleam` codec
   pattern: version-tagged, compressed Erlang terms, validated on load,
   explicit upgrade chain, `file extension .campy`.
5. Run `just check` before finishing; it must pass. Run `just fmt` first.
6. Stay inside the brief's **Files** list. If the spec seems wrong or forces a
   design decision the brief doesn't cover, **stop and report** — do not
   improvise.
7. Never add a second `campy_bridge_ffi:poll` caller in one VM. Events are
   routed to consumers by session id by the single poll owner.
8. All user-visible strings in the briefs are exact; tests depend on them.
9. Each task runs on branch `p1/<task-id>` (e.g. `p1/t0.2-manifest`). Do not
   mix tasks on one branch.

### 1.5 Dispatch prompt template

> You are implementing task `<ID> — <title>` in the Campy repository
> (`/var/home/fralalonde/Code/campy`). Read `docs/PHASE1.md` §1 (Shared
> context) and §<brief section> only; ignore other sections. Follow the brief
> exactly, including its Files list and Do-not list. Run `just fmt` and
> `just check` before finishing. If anything is ambiguous or the spec appears
> wrong, stop and report the question instead of deciding. When done, report:
> files changed, tests added, `just check` result, any deviations.

## 2. Milestone P1.0 — Pure contracts

No runtime behavior changes. All three tasks are parallelizable (T0.3 after
T0.2 lands, same package).

### T0.1 — ADR 0002: three-role architecture and OTP alignment

- Depends: none · Parallel with: T0.2 · Size: S · Risk: low
- Branch: `p1/t0.1-adr`

**Goal.** Capture the architecture decisions so later work (and humans) have
one reference.

**Spec.** Create `docs/adr/0002-three-role-architecture.md` following the
style of `docs/adr/0001-linux-ui-thread.md` (context, decision, consequences).
It must record these decisions, in this order, each with 2–4 sentences of
rationale:

1. Three roles: IDE (authors + compiles), Broker (verifies, versions, stores,
   dispatches; toolchain-free), Runner (hosts apps, applies updates, reports).
2. The IDE always compiles artifacts and pushes them; the broker never builds.
   Cross-native builds are farmed (IDE/build runner/CI) and pushed; the
   manifest carries target-tagged `natives` so dispatch can be refused early
   per runner capability.
3. Runners never see source — a workflow boundary, not a security claim.
4. Apps are supervised OTP applications (`gleam_otp`); restart intensity is
   the health signal the broker consumes; a failed handler is a contained,
   reported error, not a restart.
5. Updates follow the appup pattern: prepare → validate → migrate → pause →
   commit → resume → retire; old generation retained until commit; failed
   apply = no-op + report (app keeps running by construction).
6. Migration knowledge ships as data in the artifact (chain), computed by the
   broker, executed mechanically by the runner. Compatibility is a lattice
   (mixed-version fleets), checked before dispatch.
7. Transport: local phase uses no network; future remote phase uses iroh
   inside the Rust bridge only (transparent to apps, like Slint), with
   external term format payloads; artifacts are signed (ed25519, manifest
   field reserved now, verified before apply) so detached pull is safe and
   brokers can later federate.
8. Config is pinned per manifest version and rides artifact updates (no live
   drift). Metrics/logging are pluggable runner concerns, later.
9. Explicitly deferred: everything in the phase non-goals list (§ top).

**Files.** `docs/adr/0002-three-role-architecture.md` only.

**Do not.** Change any other doc or code. Promise anything not listed above.

**Acceptance.** Doc exists, covers all 9 points, matches ADR 0001's tone.
`just check` unaffected (docs only).

### T0.2 — Package `campy_manifest`: manifest types + codec + digest

- Depends: none · Parallel with: T0.1, (T1.1, T1.2) · Size: M · Risk: low
- Branch: `p1/t0.2-manifest`

**Goal.** A pure package defining the artifact manifest — the contract between
broker, runner, and (later) IDE transport.

**Spec.**

1. New package `gleam/packages/campy_manifest` (stdlib only; one Erlang FFI
   file for term/hash/file IO allowed).
2. Public types (exact field names):

```gleam
pub type Native {
  Native(target: String, digest: String, path: String)
}

pub type Capabilities {
  Capabilities(otp_min: Int, bridge_protocol: Int)
}

pub type Step {
  Step(from: Int, to: Int, note: String)
}

pub type Manifest {
  Manifest(
    app: String,            // slug, e.g. "cat_cafe"
    title: String,          // display title, e.g. "Cat Café"
    version: Int,           // monotonic per app, assigned by the broker
    entry_module: String,   // e.g. "campy_app_cat_cafe"
    modules: List(String),  // all beam module names in the artifact
    project_path: String,   // provenance
    module_id: String,      // provenance
    schema: Int,            // form/project codec version the form came from (today: 9)
    migration: List(Step),  // ordered chain ending at `schema`; empty in P1
    natives: List(Native),  // empty in P1
    capabilities: Capabilities,
    assets: List(String),   // referenced asset paths (not copied in P1)
    content_digest: String, // sha256 hex over the artifact's beams (see 4)
    signature: Option(String), // reserved; always None in P1
  )
}
```

3. Codec: save/load as versioned compressed Erlang terms to a
   `manifest.campy` file, copying the exact pattern of
   `campy_form/project.gleam` (version tag v1 now, `validate on load`,
   explicit error strings on mismatch). FFI lives in
   `src/campy_manifest_ffi.erl`.
4. `content_digest`: computed by an FFI function
   `digest_dir(ebin_dir) -> String` that sha256-hashes the concatenation of
   each file's (relative path, size, sha256) in sorted-path order over
   `*.beam` files. No external deps; use `crypto`.
5. Public API: `manifest.campy` save/load, `digest_dir`, `default()`
   (capabilities `Capabilities(27, 1)`), plus a `to_summary(m) -> String`
   rendering `"<app> v<version> schema<s> digest<first 8 hex>"` for console
   lines.

**Files.** `gleam/packages/campy_manifest/**` only (gleam.toml,
src/campy_manifest.gleam, src/campy_manifest_ffi.erl, test/).

**Do not.** Depend on any campy package. Add signing logic. Invent extra
fields.

**Acceptance.** `just check` green. gleeunit tests: round-trip save/load;
v1 file with wrong version tag rejected with a message containing
"unsupported manifest version"; `to_summary` exact-string test; digest_dir
is stable across two calls and changes when a beam changes (fixture dir in
test/).

### T0.3 — Migration chains: planner + mechanical executor

- Depends: T0.2 (same package) · Size: M · Risk: low
- Branch: `p1/t0.3-migration`

**Goal.** Pure functions answering "can a runner at state version X accept an
artifact at version Y, and by which steps" — the lattice check.

**Spec.** In `campy_manifest` (new module `campy_manifest/migration.gleam`):

1. `pub fn plan(from: Int, to: Int, chain: List(Step)) -> Result(List(Step), String)`
   — walks the chain from `from` to `to` in order; returns the applied steps
   or an error `"no migration path: <from> -> <to>"`. Rejects: gaps, steps out
   of order, cycles, `from == to` with a nonempty required path (that case
   returns `Ok([])`).
2. `pub fn run(state: a, steps: List(Step), up: fn(Int, a) -> a) -> a` —
   folds the state through the steps, calling `up(next_version, state)` per
   step. The caller owns the per-version upgrade logic; this is mechanical
   execution only.
3. `pub fn compatible(current: Int, target: Int, chain: List(Step)) -> Bool`.

**Files.** `gleam/packages/campy_manifest/src/campy_manifest/migration.gleam`,
its test file. Nothing else.

**Do not.** Encode any concrete project-format upgrade (dogfooding is T2.5,
out of this task). Add IO.

**Acceptance.** `just check` green. Tests cover: empty path same version,
single step, multi step, gap → error, wrong order → error, cycle → error,
run folds in order with versions passed to `up` exactly `from+1 .. to`.

## 3. Milestone P1.1 — A designed app becomes a compilable supervised unit

### T1.1 — Package `campy_app`: supervised app host runtime

- Depends: none (ABI is fixed in this brief) · Parallel with: T0.2, T1.2 ·
  Size: L · Risk: medium (flagged for G1 review) · Branch: `p1/t1.1-app-host`

**Goal.** The runtime package a generated app (and later the runner) uses to
host a designed app: supervised actor, one bridge session, event → handler
dispatch, contained handler errors, health reporting.

**Handler ABI v1 (fixed, do not change).** Handlers are the existing zero-arg
functions: `pub fn <control_name>_<event_key>() -> Nil`. Every existing
project source stays valid unchanged. ABI v2 (context argument) is future
work, noted only in a comment.

**Spec.**

1. New package `gleam/packages/campy_app`; deps: `campy_bridge`,
   `campy_form` (for `live_preview.to_slint`/`snapshot` and form types),
   `gleam_otp`, `gleam_erlang`, gleam_stdlib. Pick gleam_otp/gleam_erlang
   versions compatible with `gleam = ">= 1.16.0"`; state the chosen versions
   in the report.
2. Reports (the runner/IDE subscribes via callback):

```gleam
pub type Report {
  Started(app: String, version: Int, digest: String)
  Applied(app: String)                       // snapshot applied
  CodeUpdated(app: String, version: Int)
  HandlerError(handler: String, reason: String)
  Restarted(app: String, reason: String)     // supervisor restarted the actor
  GaveUp(app: String, reason: String)        // restart intensity exceeded
  Stopped(app: String)
  Console(line: String)                      // app-visible log line
}
```

3. `campy_app/start(config) -> Result(Ref, String)` where
   `config = Config(app: String, version: Int, digest: String, handlers_module: String, form: campy_form.Form, report: fn(Report) -> Nil, restart_limit: Int, restart_window_ms: Int)`.
   The form — not a pre-derived snapshot — is the config's payload: handler
   names derive from `Control.name` via `campy_form.handler_name`, and the
   live-preview snapshot's `PreviewControl` projection does not carry names,
   so dispatch must resolve `(control_id, event_key)` through
   `campy_form.find_control(form, id)`. The actor derives
   `live_preview.snapshot(config.form)` itself, so dispatch and rendering
   always come from one canonical form. `restart_limit`/`restart_window_ms`
   documented defaults: 3 and 10_000 (Gleam has no default arguments; provide
   a defaults helper or set them at call sites). Behavior:
   - Starts a `gleam_otp` supervisor with the configured restart intensity.
     One child: the app actor.
   - The app actor: `bridge.open_session()`, submit `LoadUi(1,
     live_preview.to_slint())`, derive and apply
      `live_preview.snapshot(config.form)` (adapt the command sequence
     from `campy_ide/live_preview_ui.gleam` — copy into
     `campy_app/preview_apply.gleam`; campy_form must stay bridge-free), then
     receive.
   - Events: the actor **never polls**. `campy_app/deliver(ref, event)` (a `campy_bridge.NativeEvent`) puts a
     message in the actor mailbox. The single poll owner (IDE loop now; runner
     process in P1.3) forwards events whose session id belongs to the app.
     Unknown sessions must be ignored by the caller, not the actor.
4. Event dispatch: resolve the control with
   `campy_form.find_control(config.form, control_id)` and map to the handler
   name via `campy_form.handler_name(control, event_key)`, then call it in the
   `handlers_module` through a new FFI `src/campy_app_ffi.erl`:

```erlang
apply_handler(Mod, Fun) ->
    try Mod:Fun() of
        Nil when Nil =:= nil -> {ok, nil}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p:~p", [Class, Reason]))}
    end.
```

   Missing function → `{error, <<"no handler">>}` via `erlang:function_exported`
   check first. Handler errors produce `HandlerError(handler, reason)` with
   reason truncated to its first line, 180 chars (mirror `short_error` in
   campy_ide.gleam). **Handler errors never restart the actor.**
5. Snapshot updates: `campy_app/apply_snapshot(ref, form)` returns `Nil`
   (fire-and-forget); the actor derives `live_preview.snapshot(form)`,
   re-applies via preview_apply, bumps an internal generation, and reports
   `Applied`. Old snapshot stays live on failure (report the error string in
   `Console`, do not crash).
6. Crash path: if the actor crashes (e.g. bridge rejects), the supervisor
   restarts it (fresh session, form re-applied) and `Restarted` is reported;
   after intensity is exceeded the supervisor stops and `GaveUp` is reported.
   `Restarted`/`GaveUp` come from a watcher process monitoring the
   supervisor's exit reasons, and `GaveUp` is suppressed during an explicit
   stop. Actor state is rebuilt from `config` — P1 apps hold no state beyond
   the form/snapshot (document this limitation in the module doc comment).
7. `campy_app/stop(ref)` → returns `Nil`, clean stop, `Stopped` report,
   session closed.

**Files.** `gleam/packages/campy_app/**` only.

**Do not.** Poll. Change campy_form, campy_bridge, or the IDE. Execute
handlers with anything richer than the fixed ABI. Persist state.

**Acceptance.** `just check` green (headless CI must pass — see test tiers).
Two test tiers:
- **Pure (always run):** `apply_handler` FFI against a fixture handler module
  (ok, raising → `HandlerError` text, missing → `no handler`, reason
  truncation); dispatch name mapping `(control_id, event_key)` → handler
  function name; report → console-line rendering.
- **Session-dependent (skip automatically unless `DISPLAY` or
  `WAYLAND_DISPLAY` is set — check via `gleam_erlang` env):** full
  start→applied→deliver→`HandlerError`→`apply_snapshot`→stop sequences via the
  public API, collecting reports with a report-collector process using
  receive/timeouts (existing IDE test style). Session flows are otherwise
  covered by the G1 manual pass.

### T1.2 — Package `campy_appgen`: project module → app source tree

- Depends: nothing code-wise (ABI fixed above) · Parallel with: T1.1 ·
  Size: M · Risk: low-medium · Branch: `p1/t1.2-appgen`

**Goal.** Pure generator: a project module becomes a standalone Gleam app
source tree. No builds, no IO beyond writing the tree.

**Spec.**

1. New package `gleam/packages/campy_appgen`; deps: `campy_form`, `campy_ccl`
   (event keys per control kind), stdlib.
2. `pub fn slug(name: String) -> String`: lowercase, keep `[a-z0-9_]`,
   everything else → `_`, collapse repeats, trim `_`, prefix with `a` if it
   starts with a digit or is empty. (Cat Café → `cat_cafe`.)
3. `pub fn generate(project: campy_form project Project, module_id: String, out_dir: String) -> Result(String, String)`
   writes (creating dirs):
   - `out_dir/gleam.toml`: name `campy_app_<module_slug>`, target erlang,
     same gleam range, deps by path `../../../gleam/packages/campy_app`,
     `../../../gleam/packages/campy_bridge`,
     `../../../gleam/packages/campy_form`,
     `../../../gleam/packages/campy_runtime`; gleeunit dev-dep. The emitted
     paths assume `out_dir` is `<repo-root>/generated/apps/<module_slug>`
     (the broker's P1 build location, T1.3): `../../../` reaches the repo
     root from there.
   - `out_dir/src/campy_app_<module_slug>.gleam`: a `main` that passes the
      embedded form (see below) to `campy_app.start`
     with `report` = print each report as one console line (format below), then
     loops forever forwarding `campy_bridge.poll` events to
     `campy_app.deliver` — the standalone app owns the single poll loop.
   - `out_dir/src/handlers_<module_slug>.gleam`: the module's `source`
     verbatim.
   - The form embeds as Gleam code, not as a runtime file read: emit a
     function `pub fn form() -> campy_form.Form` reconstructing the module's
     form (mirror how `campy_form/project.gleam`'s demo constructors build
     forms — e.g. `project.campy()` / the Cat Café constructor — using
     campy_form's public constructors). The generated main passes the form to
      `campy_app.start`; `campy_app` derives the snapshot itself.
   - Handler dispatch table: emit `handlers_module` constant string and rely
     on ABI v1 dynamic dispatch (no per-handler generated call sites).
4. Console report line format (exact):
   `"[<app>] <report-variant>"` where variants render as
   `started v<version>`, `applied`, `code-updated v<version>`,
   `handler error: <handler>: <reason>`, `restarted: <reason>`,
   `gave up: <reason>`, `stopped`, and raw text for Console lines.
5. Golden-file tests: generate for the two real modules of `campy.campy`
   (load it via `campy_form/project` in the test) into
   `test/golden/<module_slug>/` (checked into git, regenerated by a test
   helper flag or explicit function — keep deterministic: no timestamps in
   output).

**Files.** `gleam/packages/campy_appgen/**` only.

**Do not.** Run `gleam build` (that's the broker's job, T1.3). Copy assets.
Touch the IDE.

**Acceptance.** `just check` green; golden trees exist for `cat_cafe` and the
CCL widgets module; a test asserts `slug("Cat Café") == "cat_cafe"` and
`slug("9lives") == "a9lives"`; generated `gleam.toml` name matches the entry
module name in generated code.

### T1.3 — Package `campy_broker`: build port + artifact assembly

- Depends: T0.2, T1.2 · Size: M · Risk: medium · Branch: `p1/t1.3-broker-build`

**Goal.** `broker.build(project, module) -> artifact dir + Manifest`, all
local: generate the app, compile it with a `gleam build` port (the IDE-pushes
model, phase 1 edition), assemble and digest the artifact.

**Spec.**

1. New package `gleam/packages/campy_broker`; deps: `campy_manifest`,
   `campy_appgen`, `campy_form`, stdlib. Erlang FFI
   `src/campy_broker_ffi.erl`.
2. FFI `run_build(dir) -> Result(String, String)`: port-spawn `gleam build`
   in `dir`, merge stderr into stdout, 180 s timeout — a direct adaptation of
   `campy_hot_ffi.erl`'s `run_build/collect` (same exit-status handling,
   same error text shapes: `"gleam build failed (<code>): <output>"` and
   `"gleam build timed out"`).
3. App source trees go to `generated/apps/<module_slug>/` (delete the dir's
   previous contents first — regeneration is always clean).
4. Artifacts go to `generated/broker/artifacts/<module_slug>/<version>/`
   containing exactly: `manifest.campy` and `ebin/` (the
   `build/dev/erlang/<package>/ebin` beams; only `campy_app_<slug>` and
   `handlers_<slug>` beams — **not** campy_* dependency beams, which the
   host VM already has; list what was copied in `modules`).
5. Versioning: `next_version(<module_slug>)` = 1 if no artifact dir exists,
   else max existing + 1 (plain filesystem read, no state file — the state
   file is T2.1).
6. `pub fn build(project, module_id) -> Result(#(String, Manifest), String)`
   — generate → build → assemble → digest via `campy_manifest.digest_dir` →
   save manifest (capabilities `Capabilities(27, 1)`, natives `[]`,
   migration `[]`, signature `None`, schema = `campy_form/project`'s public
   `version` constant (currently 11; read the constant, never hardcode the
   number). Returns artifact dir and manifest.
7. On build failure, return the FFI error verbatim; artifact dir untouched.

**Files.** `gleam/packages/campy_broker/**` only.

**Do not.** Track deployment state (T2.1). Run the app. Add a network
anything.

**Acceptance.** `just check` green. A test (allowed to invoke `gleam` —
mark it and skip when `CAMPY_FAST_ONLY` env var is set) builds the CCL
Widgets module (module id `widgets`) from `campy.campy` and asserts:
artifact contains manifest + the two beams, digest is 64 hex chars, manifest
fields match the brief (app slug `widgets`, version 1, modules sorted), and
a second `build` produces version 2. Use `widgets`, not the Cat Café module:
its committed handler stubs are valid Gleam, while the Cat Café demo's
handler body contains manual test edits that do not compile (live demo data
must not be a test dependency). `just check` must remain green both with and
without `CAMPY_FAST_ONLY`.

### T1.4 — End-to-end build integration + just target

- Depends: T1.3 · Size: S · Risk: low · Branch: `p1/t1.4-build-target`

**Goal.** A single command proves the pipeline outside unit tests.

**Spec.**

1. `scripts/workspace.py`: add command `build-app` with an optional module-id
   argument (default: the active project's `widgets` module — its handlers
   compile; see T1.3's note about the Cat Café demo). It
   loads the project file, calls the broker build via
   `erl -noshell -eval` (same pattern the file already uses for OTP-version
   probes), and prints the manifest summary line and artifact path.
2. `justfile`: add `build-app` recipe calling it. Keep style consistent with
   neighboring recipes.
3. Update `docs/README`-level docs: add two sentences under "State and
   limits" in `README.md` noting the experimental `just build-app` and what
   it produces. No other doc changes.

**Files.** `scripts/workspace.py`, `justfile`, `README.md`.

**Do not.** Wire the IDE to the broker (that's T2.3).

**Acceptance.** `just build-app` (default module) prints the summary line and
creates the artifact; `just check` green.

## 4. Milestone P1.2 — Local broker/runner seams, transparent UX

### T2.1 — Broker store + deployment state

- Depends: T0.2 (full e2e with T1.3) · Parallel with: T1.1 · Size: M ·
  Risk: low · Branch: `p1/t2.1-broker-store`

**Goal.** The broker's memory: published artifacts + deployment state as a
versioned term file (the local ancestor of "a repo per broker").

**Spec.**

1. In `campy_broker`, state file `generated/broker/state.campy`, codec v1
   using the `campy_form/project.gleam` pattern:

```gleam
pub type Deployment {
  Deployment(app: String, version: Int, runner: String,
             status: String,   // "applied" | "failed" | "reported-failed"
             detail: String, at_ms: Int)
}

pub type BrokerState {
  BrokerState(current: List(#(String, Int)),        // app -> latest published version
              deployments: List(Deployment),        // capped at 500, newest first
  )
}
```

2. API in `campy_broker/state_store.gleam`: `load() -> BrokerState` (missing
   file → empty state), `save(state)`, `publish(state, app, version)`,
   `record_deployment(state, deployment)`, `latest(state, app)`.
3. Losing the file (e.g. `just clean` wipes `generated/`) is acceptable and
   documented in the module comment: local P1 state is advisory, rebuilt by
   the next Run. No recovery logic.
4. `record_report(state, app, version, outcome)`: outcome applied →
   `"applied"`; apply-failed → `"failed"` with detail = first line 180 chars;
   a later successful apply of the same version upgrades the entry to
   `"applied"`.

**Files.** `gleam/packages/campy_broker/src/campy_broker/state_store.gleam`
(+ FFI additions in `campy_broker_ffi.erl` if needed), tests.

**Do not.** Add runnables, networks, or anything beyond file IO.

**Acceptance.** `just check` green; tests: round-trip, cap at 500, record
report transitions failed→applied, load-missing returns empty.

### T2.2 — Package `campy_runner`: in-VM runner

- Depends: T1.1 (hard), T1.3 (for `update_code`) · Size: M · Risk: medium ·
  Branch: `p1/t2.2-runner`

**Goal.** The runner seam: owns app hosting, exposes the interface the IDE
(and later a transport) speaks. Phase 1 implementation hosts the app **in the
IDE's own VM**, supervised, as a loaded module set + bridge session.

**Spec.**

1. New package `gleam/packages/campy_runner`; deps: `campy_app`,
   `campy_broker` (artifact/manifest types + state recording),
   `campy_manifest`, `campy_bridge`, `campy_form`, `gleam_erlang` (module
   loading), stdlib. FFI `src/campy_runner_ffi.erl`.
2. Public API:

```gleam
pub type Ref

pub fn start(artifact_dir: String, report: fn(Report) -> Nil) -> Result(Ref, String)
pub fn apply_snapshot(ref: Ref, form: Form) -> Result(Nil, String)   // fast path, no build
pub fn update_code(ref: Ref, artifact_dir: String) -> Result(Nil, String)
pub fn deliver(ref: Ref, event: NativeEvent) -> Nil
pub fn status(ref: Ref) -> Status   // Running{app, version, generation, restarts} | Dead{reason}
pub fn stop(ref: Ref) -> Nil
```

3. `start`: read the artifact's manifest; `code:add_patha(<artifact>/ebin)`
   via FFI; load each `modules` entry with the soft-purge discipline copied
   from `campy_hot_ffi.erl` (`code:soft_purge` then `code:load_file`;
   on `not_purged`, retry once via `code:purge` — the app actor is suspended
   across the swap, see 4); then `campy_app.start` with the module's form
   reloaded from the manifest's provenance (the artifact deliberately does not
   embed the form in P1; it reloads from the same project the IDE has open,
   which is identical by construction).
4. `update_code(new artifact)`: pause (suspend the app actor's processing —
   simplest correct P1 mechanism: the runner stops delivering events and
   awaits an ack of quiescence from the actor mailbox being empty via a
   synchronous ping message), soft-purge + load new modules, re-apply the
   current snapshot, resume delivery, report `CodeUpdated`. **Failure
   anywhere before the purge leaves the old code and old session live —
   return the error, keep running, record a failed deployment (T2.1).** A
   purge failure (old module still executing) aborts the update the same
   way; the next update retries.
5. Event routing: `deliver` filters by the app's session id (from `status`)
   and forwards to `campy_app.deliver`.
6. Reports from `campy_app` are forwarded to the caller's `report` callback,
   prefixed with nothing (verbatim); the runner adds one report of its own on
   successful `update_code` and records deployments via `state_store`.

**Files.** `gleam/packages/campy_runner/**` only.

**Do not.** Poll. Open windows itself. Touch the IDE. Support two instances
of the same app simultaneously (explicit `Error("app already running")`).

**Acceptance.** `just check` green. Tests in two tiers, same rule as T1.1
(pure always; session-dependent skip unless `DISPLAY`/`WAYLAND_DISPLAY`
set):
- Pure: status rendering; `deliver` filtering by session id (fake events);
  state_store recording from a simulated failed apply; module-list loading
  order per the brief.
- Session-dependent (fixture artifact built by the T1.3 helper, which itself
  skips under `CAMPY_FAST_ONLY`): start → status Running v1; update_code with
  a v2 artifact (fixture: regenerate with a tweaked handler comment) swaps
  modules and re-applies; update_code with a corrupt beam file fails without
  killing the app (status still Running, old version).

### T2.3 — IDE re-route: Run/F7/Stop through broker+runner (transparency)

- Depends: T1.4, T2.1, T2.2 · Size: L · Risk: medium-high (flagged for G2) ·
  Branch: `p1/t2.3-ide-route`

**Goal.** The only UX-visible milestone — and it must stay invisible: same
keys, same windows, plus honest console lines and a one-time compile on Run.

**Spec.**

1. In `campy_ide.gleam` (and `campy_ide/state.gleam` where the `Preview`
   record lives):
   - `Preview` now holds the `campy_runner.Ref` + module id (drop the raw
     bridge session from state).
   - **Run** (`run_form`): existing `gate_compile_errors` gate → status
     "Compiling…" → `campy_broker.build` → `campy_broker.state_store
     publish` → `campy_runner.start` with a report callback that appends to
     the IDE console (exact lines below). Failure at any step: existing
     error-status style ("Cannot run: <first line, 180 chars>").
   - **F7** (`update_app`): fast path only — `runner.apply_snapshot` with the
     active module's form (no build). If handler source changed since Run
     (track a dirty flag set by handler Apply / code-edit commit, cleared by
     Run or update-code), F7 instead does status "Compiling…" →
     `broker.build` → `runner.update_code` → record deployment → clear flag.
     Same key, one behavior, no new UI.
   - **Stop** (`stop_form`): `runner.stop`.
   - Event routing: the existing loop's `preview_event` branch becomes:
     session match → `runner.deliver(event)`; runner reports (console) are
     produced by the report callback, not event parsing. The
     `callback:event` label line format is unchanged
     (`"Event: <handler_name>"`) — produce it inside the report callback via
     `campy_form.handler_name` from the event payload, preserving today's
     console text exactly.
2. Console lines (exact, appended via `state.log_console`):
   - Run success: `"▶ Running <module> (<manifest summary>)"` where
     `<manifest summary>` is `campy_manifest.to_summary` output.
   - Update-code success: `"⟳ Updated <module> (<summary>)"`.
   - Apply-snapshot F7: keep today's `"⟳ Updated <module>"` unchanged.
   - Stop: keep `"■ App stopped"`.
   - Runner reports: `HandlerError` → `"⚠ handler error: <handler>: <reason>"`;
     `Restarted` → `"⚠ app restarted: <reason>"`; `GaveUp` →
     `"■ App stopped (crash loop)"` and clear the Preview record.
3. MCP tools `run`/`stop`/`update_app` keep working unchanged (they call the
   same functions — verify no signature drift).
4. `campy_ide/live_preview_ui.gleam`: now unused by Run — delete it and its
   imports (grep first; if something else still calls it, report instead of
   deleting).
5. Existing IDE tests: update only where console/status strings above
   dictate; no opportunistic fixture edits.

**Files.** `gleam/apps/campy_ide/src/campy_ide.gleam`,
`campy_ide/state.gleam`, deletion of `campy_ide/live_preview_ui.gleam`, test
fixtures as strictly required.

**Do not.** Add UI elements, settings, or keybindings. Change F6. Change the
bridge or Rust. Reroute through any process boundary (P1.3).

**Acceptance.** `just check` green. Manual (report in the task summary, with
the console transcript): Run Cat Café → window opens, console shows the
summary line; click a button with a raising fixture handler → `⚠ handler
error` line and the window keeps working; edit + Apply a handler body → F7
shows "Compiling…" then the update line; F7 again (no edit) shows the plain
snapshot line; Stop; crash-loop fixture (a handler that halts the actor is
**not** possible via ABI v1 — instead simulate by killing the session in a
test) reports restart/gave-up lines correctly in the unit test.

### T2.4 — Pre-dispatch compatibility check

- Depends: T0.3, T2.1, T2.2 · Size: S · Risk: low · Branch: `p1/t2.4-compat`

**Goal.** The broker refuses what the runner can't apply — before dispatch.

**Spec.**

1. `campy_broker/can_deploy(state, app, target_manifest) -> Result(Nil, String)`:
   uses `campy_manifest/migration.compatible` between the runner-recorded
   version's schema (from the last deployment entry; default current) and
   the target manifest's schema + its `migration` chain. Errors:
   `"no migration path: <from> -> <to>"` (from the planner) or
   `"runner capability below artifact requirement"` when
   `target.capabilities.otp_min` > the runtime's actual OTP release (get it
   via `erlang:system_info(otp_release)` FFI) or `bridge_protocol` >
   `campy_bridge.protocol_version()`.
2. In `campy_ide.gleam`'s Run and update paths (T2.3): call `can_deploy`
   after build, before start/update; on error show it via the existing
   status line ("Cannot run: <reason>") and do not start.
3. Test: manifest with schema 10 + a chain 9→10 deploys to a runner last at
   schema 9; a chain with a gap refuses with the planner's message.

**Files.** `gleam/packages/campy_broker/**`, small hook in
`campy_ide.gleam` (reuse T2.3 seams).

**Do not.** Make it async or broker-process-owned; it's a pure check inline
in P1.

**Acceptance.** `just check` green + the two tests above.

### T2.5 — (Stretch, do last) Dogfood the migration chain on the project codec

- Depends: T2.4, G2 passed · Size: M · Risk: medium — touches the load path
  of every project file · Branch: `p1/t2.5-dogfood`

**Goal.** Replace `campy_form/project.gleam`'s hand-rolled v1→v9 upgrade
sequence with `campy_manifest/migration.plan + run`, so the machinery gets
real-world exercise on Campy's own 9-version history.

**Spec.** The per-version upgrader functions stay as-is; only the sequencing
becomes `plan(from, to, all_steps)` + `run(term, steps, up)`. All existing
v1→v9 fixtures in the project codec tests must load identically. If the
upgrade functions' shapes don't fit `run`'s fold cleanly (e.g. they need the
file path), **stop and report** instead of changing signatures — this task
may end in "not worth it now" and that's an acceptable outcome.

**Acceptance.** `just check` green; no behavior change on any fixture;
summary states whether the fold fit or the task aborted.

### T2.6 — Docs sync

- Depends: T2.3 · Size: S · Risk: low · Branch: `p1/t2.6-docs`

**Spec.** Update `docs/ARCHITECTURE.md`: add a "Three roles (P1)" section
after "IDE surface" describing broker/runner seams, the artifact layout under
`generated/broker/`, the report taxonomy, and pointing to ADR 0002 and this
plan. Update the MVP doc's "State and limits" mapping (one paragraph: M1
descriptor work deferred; the P1 artifact/ABI v1 path landed first per
ADR 0002). Two sentences max in `README.md` state/limits if behavior notes
warrant.

**Acceptance.** Docs render, `just check` green.

## 5. Milestone P1.3 — Runner as an OS process (GATED)

Do not dispatch any P1.3 task before gates G2 and G3 pass. P1.3 replaces the
in-VM runner of T2.2 for Run/F7/Stop with a child OS process, transparently.

### T3.1 — ETF framing codec

- Depends: gate · Size: S · Risk: low · Branch: `p1/t3.1-framing`

**Spec.** `campy_runner/frame.gleam` + FFI: `encode(term) -> BitArray`
(4-byte big-endian length prefix + `term_to_binary`), `decode(BitArray) ->
Result(#(term, rest), String)`; malformed/truncated → errors. Tests:
round-trip WireValue-ish nested data, split frames, garbage after frame,
truncated frame. No network code.

### T3.2 — Runner executable

- Depends: T3.1, T2.2 · Size: L · Risk: medium-high (G3 review) · Branch:
  `p1/t3.2-runner-app`

**Spec.** New runnable `gleam/apps/campy_runner` (name it `campy_runner_host`
if the package name collides — check and report): a main loop reading
length-prefixed ETF commands on stdin (`hello`, `start{artifact_dir}`,
`apply_snapshot{form-term}`, `update_code{artifact_dir}`, `stop`, `poll`)
and writing length-prefixed ETF events/reports (runner status + campy_app
`Report`s + event tuples) to stdout. It owns the single `bridge.poll` loop.
`scripts/workspace.py` gains `export-runner` (erlang-shipment + staged NIF,
reusing the existing export/stage machinery; no Rust changes). A smoke mode
`--selftest` runs start/apply/stop on a fixture artifact headlessly where
possible and exits 0/1.

### T3.3 — IDE transport client + spawn

- Depends: T3.2 · Size: M · Risk: medium · Branch: `p1/t3.3-transport`

**Spec.** In `campy_runner` (client side): spawn the runner executable as a
port (path from `generated/dist/…` or `build/erlang-shipment`, as staged by
T3.2), handshake `hello`, and implement the same `Ref` API as T2.2 over
frames (start/apply_snapshot/update_code/deliver now serialize). Timeout per
command 10 s; runner death → status Dead + console line
`"■ App stopped (runner exited)"`; IDE loop integrates with the existing
port message flow. Run/F7/Stop choose child-process runner instead of in-VM
via a Settings-independent constant for now (default: child process; the
in-VM path stays for tests). F7 latency budget: one round trip.

### T3.4 — Update hardening + report queue

- Depends: T3.3 · Size: M · Risk: medium · Branch: `p1/t3.4-hardening`

**Spec.** Bounded cooperative pause around `update_code` (busy app defers
once, 2 s, then applies anyway; report the deferral). Failed updates spool
reports to `generated/runner-<pid>/reports/` (one term file per report,
cap 200) and retry delivery to the IDE on each subsequent command; IDE
flushes them to console. Unit tests with fake pipes (no real process
needed for the spool/retry logic).

## 6. Gates and review economy

| Gate | After | Who reviews | What |
| --- | --- | --- | --- |
| G0 | P1.0 (T0.1–T0.3) | GLM-5.3, skim (~15 min) | Types/APIs match briefs; ADR reads right |
| G1 | P1.1 (T1.1–T1.4) | GLM-5.3, full | Read the generated Cat Café app end-to-end; dispatch/ABI semantics; artifact contents |
| G2 | P1.2 (T2.1–T2.4, T2.6) | GLM-5.3, full + user | campy_ide diff; manual Run/F7/Stop pass; transparency sign-off |
| G3 | before P1.3 | GLM-5.3 + user, design only | Protocol + packaging design (T3.2/T3.3 briefs) |

Cheap-agent dispatch rules: one brief per session (§1.5 template); never let
an agent pick up a task whose dependencies aren't merged; T1.1, T2.3, T3.2
summaries must include a short self-review of every Do-not item.

## 7. Suggested dispatch order

```
Wave 1 (parallel):  T0.1  T0.2  T1.1  T1.2
Wave 2:             T0.3  T1.3  T2.1        (after T0.2 / T1.2 land)
Wave 3:             T1.4  T2.2              (after T1.3 / T1.1)
Wave 4:             T2.3  T2.4  T2.6        (after T2.1 + T2.2; T2.4 after T0.3)
Wave 5 (stretch):   T2.5                    (only after G2)
GATED:              T3.1 → T3.2 → T3.3 → T3.4   (after G2 + G3)
```

Merge order within a wave doesn't matter; across waves it does. After each
wave, the expensive model runs the gate check and merges.
