//// The broker's memory: published artifact versions and deployment state.
////
//// State lives in one versioned compressed Erlang term,
//// `generated/broker/state.campy`, following the codec pattern of
//// `campy_form/project.gleam`: an explicit format version tag, validation on
//// load, and an empty state for a missing or unreadable file.
////
//// Local phase-1 state is advisory. Wiping `generated/` (for example with
//// `just clean`) loses the record, and the next Run rebuilds it from the
//// artifact tree. There is no recovery or repair logic on purpose.
////
//// The transformed states are values: `publish`, `record_deployment` and
//// `record_report` do not write anything. Callers persist with `save`.

import campy_broker
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Deployment history is capped so the state file stays small and bounded.
pub const max_deployments = 500

/// One apply of an app version on a runner.
///
/// `status` is `"applied"` (deployed and confirmed), `"failed"` (the apply
/// failed at dispatch time, broker-side), or `"reported-failed"` (a runner
/// reported a failed update for a recorded deployment after the fact).
/// `at_ms` is wall-clock milliseconds.
pub type Deployment {
  Deployment(
    app: String,
    version: Int,
    runner: String,
    status: String,
    detail: String,
    at_ms: Int,
  )
}

/// The broker's whole local state: the latest published version per app and
/// the deployment history, newest first.
pub type BrokerState {
  BrokerState(current: List(#(String, Int)), deployments: List(Deployment))
}

/// The result of one apply report.
pub type ReportOutcome {
  /// The version is deployed and confirmed.
  Applied
  /// The broker could not dispatch the apply.
  ApplyFailed(detail: String)
  /// A runner reported a failed update after the fact.
  ReportedFailed(detail: String)
}

@external(erlang, "campy_broker_ffi", "save_state")
fn write_state(path: String, state: BrokerState) -> Result(Nil, String)

@external(erlang, "campy_broker_ffi", "load_state")
fn read_state(path: String) -> Result(BrokerState, String)

@external(erlang, "campy_broker_ffi", "now_ms")
fn now_ms() -> Int

fn state_path() -> String {
  campy_broker.root() <> "/generated/broker/state.campy"
}

/// Loads the broker state. A missing, unreadable, or unsupported file yields
/// the empty state; local phase-1 state is advisory.
pub fn load() -> BrokerState {
  load_from(state_path())
}

/// Loads state from an explicit path, with the same empty-on-failure rule as
/// `load`. Used by tests and by callers that keep state under another root.
pub fn load_from(path: String) -> BrokerState {
  case read_state(path) {
    Ok(state) -> state
    Error(_) -> BrokerState(current: [], deployments: [])
  }
}

/// Persists the state as a versioned compressed Erlang term.
pub fn save(state: BrokerState) -> Result(Nil, String) {
  save_to(state, state_path())
}

/// Persists state to an explicit path. Used by tests and by callers that keep
/// state under another root.
pub fn save_to(state: BrokerState, path: String) -> Result(Nil, String) {
  write_state(path, state)
}

/// Records `version` as the latest published version of `app`.
///
/// Current versions are kept sorted by app name so the file is canonical.
pub fn publish(state: BrokerState, app: String, version: Int) -> BrokerState {
  let current =
    state.current
    |> list.filter(fn(entry) { entry.0 != app })
    |> list.append([#(app, version)])
    |> list.sort(by: fn(left, right) { string.compare(left.0, right.0) })
  BrokerState(..state, current: current)
}

/// The latest published version of `app`, if it was ever published.
pub fn latest(state: BrokerState, app: String) -> Option(Int) {
  case list.find(state.current, fn(entry) { entry.0 == app }) {
    Ok(#(_, version)) -> Some(version)
    Error(_) -> None
  }
}

/// Prepends a deployment to the history, keeping the newest 500.
pub fn record_deployment(
  state: BrokerState,
  deployment: Deployment,
) -> BrokerState {
  BrokerState(..state, deployments: cap([deployment, ..state.deployments]))
}

/// Applies a report to the newest recorded deployment of `app` + `version`.
///
/// `Applied` upgrades that entry to `"applied"` whatever its prior status was.
/// `ApplyFailed` records `"failed"` and `ReportedFailed` records
/// `"reported-failed"`; both keep only the first line of the detail, truncated
/// to 180 characters. When no deployment of that app and version is recorded,
/// the report is added as a new entry with an empty runner, so no report is
/// silently lost.
pub fn record_report(
  state: BrokerState,
  app: String,
  version: Int,
  outcome: ReportOutcome,
) -> BrokerState {
  let #(status, detail) = case outcome {
    Applied -> #("applied", "")
    ApplyFailed(error) -> #("failed", first_line(error))
    ReportedFailed(error) -> #("reported-failed", first_line(error))
  }
  let at_ms = now_ms()
  let deployments = case has_deployment(state.deployments, app, version) {
    True ->
      update_deployment(state.deployments, app, version, status, detail, at_ms)
    False ->
      cap([
        Deployment(
          app: app,
          version: version,
          runner: "",
          status: status,
          detail: detail,
          at_ms: at_ms,
        ),
        ..state.deployments
      ])
  }
  BrokerState(..state, deployments: deployments)
}

fn cap(deployments: List(Deployment)) -> List(Deployment) {
  list.take(deployments, max_deployments)
}

fn has_deployment(
  deployments: List(Deployment),
  app: String,
  version: Int,
) -> Bool {
  list.any(deployments, fn(deployment) {
    deployment.app == app && deployment.version == version
  })
}

// The list is newest first, so this updates the newest matching entry only.
fn update_deployment(
  deployments: List(Deployment),
  app: String,
  version: Int,
  status: String,
  detail: String,
  at_ms: Int,
) -> List(Deployment) {
  case deployments {
    [] -> []
    [deployment, ..rest] ->
      case deployment.app == app && deployment.version == version {
        True -> [
          Deployment(..deployment, status: status, detail: detail, at_ms: at_ms),
          ..rest
        ]
        False -> [
          deployment,
          ..update_deployment(rest, app, version, status, detail, at_ms)
        ]
      }
  }
}

// Detail is the first line of the error text, trimmed at the end and cut to
// 180 characters.
fn first_line(text: String) -> String {
  let line = case string.split(text, "\n") {
    [first, ..] -> first
    [] -> ""
  }
  string.slice(string.trim_end(line), 0, 180)
}
