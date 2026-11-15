import campy_broker/state_store.{
  type BrokerState, type Deployment, Applied, ApplyFailed, BrokerState,
  Deployment, ReportedFailed,
} as store
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

@external(erlang, "campy_broker_test_ffi", "temp_dir")
fn temp_dir(prefix: String) -> String

@external(erlang, "campy_broker_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

pub fn main() {
  gleeunit.main()
}

fn empty() -> BrokerState {
  BrokerState(current: [], deployments: [])
}

fn sample() -> BrokerState {
  BrokerState(current: [#("cat-cafe", 3), #("widgets", 1)], deployments: [
    Deployment(
      app: "cat-cafe",
      version: 3,
      runner: "local",
      status: "applied",
      detail: "",
      at_ms: 1_700_000_000_000,
    ),
    Deployment(
      app: "widgets",
      version: 1,
      runner: "local",
      status: "failed",
      detail: "compile error",
      at_ms: 1_700_000_000_001,
    ),
  ])
}

fn state_file() -> String {
  temp_dir("campy-broker-state") <> "/state.campy"
}

fn versions(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..versions(from + 1, to)]
  }
}

fn head(state: BrokerState) -> Deployment {
  case state.deployments {
    [deployment, ..] -> deployment
    [] -> panic as "expected a deployment"
  }
}

// --- Codec ------------------------------------------------------------------

pub fn load_missing_file_is_empty_test() {
  store.load_from(state_file() <> "/missing.campy")
  |> should.equal(empty())
}

pub fn save_load_round_trip_test() {
  let path = state_file()
  store.save_to(sample(), path) |> should.equal(Ok(Nil))
  store.load_from(path) |> should.equal(sample())
}

pub fn unreadable_file_is_empty_test() {
  let path = state_file()
  let assert Ok(Nil) = write_file(path, "this is not an Erlang term")
  store.load_from(path) |> should.equal(empty())
}

// --- Current versions -------------------------------------------------------

pub fn publish_and_latest_test() {
  let state =
    empty()
    |> store.publish("widgets", 1)
    |> store.publish("cat-cafe", 2)

  // Current versions are canonical: sorted by app name.
  state.current
  |> should.equal([#("cat-cafe", 2), #("widgets", 1)])
  store.latest(state, "cat-cafe") |> should.equal(Some(2))
  store.latest(state, "missing") |> should.equal(None)

  // Publishing an app again replaces its version in place.
  let state = store.publish(state, "widgets", 3)
  state.current
  |> should.equal([#("cat-cafe", 2), #("widgets", 3)])
  list.length(state.current) |> should.equal(2)
}

// --- Deployment history -----------------------------------------------------

pub fn deployments_capped_at_500_newest_first_test() {
  let state =
    versions(1, 510)
    |> list.fold(empty(), fn(state, version) {
      store.record_deployment(
        state,
        Deployment(
          app: "app",
          version: version,
          runner: "runner",
          status: "applied",
          detail: "",
          at_ms: version,
        ),
      )
    })

  list.length(state.deployments) |> should.equal(500)
  head(state)
  |> should.equal(Deployment(
    app: "app",
    version: 510,
    runner: "runner",
    status: "applied",
    detail: "",
    at_ms: 510,
  ))
  list.last(state.deployments)
  |> should.equal(
    Ok(Deployment(
      app: "app",
      version: 11,
      runner: "runner",
      status: "applied",
      detail: "",
      at_ms: 11,
    )),
  )
}

pub fn record_report_upgrades_failed_to_applied_test() {
  let state =
    empty()
    |> store.record_deployment(Deployment(
      app: "cat-cafe",
      version: 3,
      runner: "local",
      status: "applied",
      detail: "",
      at_ms: 1,
    ))

  // A dispatch-time failure turns the recorded deployment into "failed" and
  // keeps only the first line of the error.
  let state =
    store.record_report(
      state,
      "cat-cafe",
      3,
      ApplyFailed("dispatch boom\nmore"),
    )
  let failed = head(state)
  failed.status |> should.equal("failed")
  failed.detail |> should.equal("dispatch boom")
  failed.runner |> should.equal("local")
  failed.version |> should.equal(3)
  failed.at_ms |> should.not_equal(1)

  // A later successful apply of the same version upgrades the entry.
  let state = store.record_report(state, "cat-cafe", 3, Applied)
  let applied = head(state)
  applied.status |> should.equal("applied")
  applied.detail |> should.equal("")
  applied.runner |> should.equal("local")
  applied.version |> should.equal(3)
  list.length(state.deployments) |> should.equal(1)
}

pub fn record_report_marks_reported_failed_test() {
  let state =
    empty()
    |> store.record_deployment(Deployment(
      app: "widgets",
      version: 2,
      runner: "local",
      status: "applied",
      detail: "",
      at_ms: 1,
    ))
    |> store.record_report(
      "widgets",
      2,
      ReportedFailed("runner lost the app\nstack line"),
    )

  let reported = head(state)
  reported.status |> should.equal("reported-failed")
  reported.detail |> should.equal("runner lost the app")
  reported.runner |> should.equal("local")
  list.length(state.deployments) |> should.equal(1)
}

pub fn failure_detail_is_first_line_180_chars_test() {
  let long = string.repeat("x", 300)
  let state =
    store.record_report(empty(), "app", 1, ApplyFailed(long <> "\nsecond line"))
  let deployment = head(state)
  deployment.detail |> should.equal(string.repeat("x", 180))
  string.length(deployment.detail) |> should.equal(180)
}

pub fn report_without_recorded_deployment_is_kept_test() {
  let state = store.record_report(empty(), "app", 1, ReportedFailed("boom"))
  let deployment = head(state)
  deployment.status |> should.equal("reported-failed")
  deployment.runner |> should.equal("")
  list.length(state.deployments) |> should.equal(1)
}
