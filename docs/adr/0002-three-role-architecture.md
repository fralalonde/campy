# ADR 0002: three-role architecture and OTP alignment

Status: accepted for Phase 1.

## Context

Campy today is one OS process: a Gleam IDE on the BEAM with a Rust NIF that owns
the Slint UI thread. The IDE authors projects, opens preview sessions in the
same VM, and rebuilds itself through a port. Three roles — IDE, broker, runner —
already exist de facto inside that process; Phase 1 makes them explicit seams
without adding a network or new user-visible concepts. The guiding principle is
OTP alignment: apps are supervised `gleam_otp` applications and updates follow
the appup shape, so Campy stands on the runtime's restart, isolation, and release
semantics instead of inventing its own. The reload protocol in
`docs/ARCHITECTURE.md` and milestones M1–M3 in `docs/MVP.md` are the doctrinal
background.

## Decision

### 1. Three roles

Campy has three roles. The IDE authors projects and compiles artifacts. The
broker verifies, versions, stores, and dispatches artifacts, and is
toolchain-free. The runner hosts apps as supervised OTP applications, applies
updates, and reports results and health. Splitting the roles keeps each one
replaceable: the broker can be a small durable service, the runner can outlive
it, and the IDE carries all authoring and build complexity. In Phase 1 all three
are local and in-process except the P1.3 runner process; the seams are chosen so
later placement does not change the contracts.

### 2. The IDE builds; the broker never does

The IDE always compiles artifacts and pushes the result; the broker never builds.
A broker that compiled would need every target toolchain, so it could not stay
small, auditable, and toolchain-free. Cross-native builds are farmed to the IDE,
a build runner, or CI and pushed like any other artifact. The manifest carries
target-tagged `natives`, which lets dispatch be refused early when a runner
cannot host the artifact's target.

### 3. Runners never see source

Runners receive built artifacts and never source. This is a workflow boundary,
not a security claim: it keeps the runner free of compilers and build inputs and
makes the artifact the only thing that must be versioned and verified. It also
means a runner can be restarted or replaced without recovering an authoring
environment.

### 4. Apps are supervised OTP applications

Every app runs as a supervised OTP application built on `gleam_otp`. Supervision
gives each app a tree with an explicit restart policy, so a fault stays inside
the app instead of spreading through the runner. Restart intensity is the health
signal the broker consumes: a quiet tree indicates health, while repeated
restarts indicate an unstable generation. A failed handler is a contained,
reported error, not a restart; handler failure is application data, and reporting
it is cheaper and more precise than cycling the supervision tree.

### 5. Updates follow the appup pattern

Updates follow the appup pattern: prepare, validate, migrate, pause, commit,
resume, retire. The old generation is retained until commit, so every step before
commit can be abandoned without touching the running app. A failed apply is
therefore a no-op plus a report, and the app keeps running by construction rather
than by recovery logic. This mirrors OTP release handling and keeps the failure
mode boring.

### 6. Migrations are data, compatibility is a lattice

Migration knowledge ships as data in the artifact as an explicit chain. The
broker computes the chain from the manifest's versions; the runner executes it
mechanically and holds no migration code of its own. Compatibility is a lattice,
not a line, because fleets can run mixed versions and one update may have to be
reachable from several predecessors. The broker checks that lattice before
dispatch, so an impossible move is refused before an app is disturbed.

### 7. Transport and signing direction

The local phase uses no network; roles communicate in-process and, from P1.3,
across local OS process boundaries. A future remote phase uses iroh inside the
Rust bridge only, transparent to apps in the same way Slint is, with external
term format payloads. Artifacts will be signed with ed25519; the manifest field
is reserved now and verification will happen before apply. Signing makes
detached pull safe and leaves room for brokers to federate later without changing
the artifact contract.

### 8. Config is pinned; observability is a runner concern

Configuration is pinned per manifest version and rides artifact updates; there
is no live configuration channel. A deployment is therefore a function of one
artifact version, which keeps rollback and reproduction exact and removes
configuration drift as a failure class. Metrics and logging are pluggable runner
concerns and are deliberately left for later, so instrumentation does not enter
the artifact contract now.

### 9. Deferred work

The following are explicitly deferred and are not built or stubbed in Phase 1:
iroh transport, artifact signing and verification, broker federation, remote
runners, web and CLI management UIs, app persistent-state migrations, config
tracking, and metrics. Decision 7 records the direction for transport and
signing so later work starts from a stated position instead of reopening the
architecture. Deferring these keeps Phase 1 focused on compilable apps and local
seams.

## Consequences

- The broker is not a build service. Builds that must happen elsewhere belong to
  the IDE, a build runner, or CI, and arrive as pushed artifacts.
- A runner has no compiler and no source. Diagnosing an app fault relies on
  reported errors, restart history, and the artifact, not on code on the host.
- The artifact is the unit of versioning, storage, dispatch, and rollback. The
  manifest must be complete enough for the broker to verify without executing
  anything.
- Migration chains are authored data, so a version bump without a chain is a
  deliberate refusal rather than an accident.
- The old generation stays resident until commit. This costs memory during an
  update and bounds the rollback window.
- Configuration changes require a new artifact version. There is no live tuning
  path in this phase.
- In Phase 1 the roles share one VM, so a role bug can still affect the others.
  P1.3 moves the runner out; later transport work addresses the rest.
