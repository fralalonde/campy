import campy_app
import campy_bridge
import campy_broker
import campy_broker/state_store
import campy_form/project as project_codec
import campy_runner
import campy_runner/deployment
import campy_runner/routing
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

@external(erlang, "campy_runner_ffi", "has_display")
fn has_display() -> Bool

@external(erlang, "campy_runner_ffi", "getenv")
fn getenv(name: String) -> Option(String)

@external(erlang, "campy_runner_ffi", "add_path")
fn runner_add_path(ebin: String) -> Result(Nil, String)

@external(erlang, "campy_runner_ffi", "load_modules")
fn runner_load_modules(
  ebin: String,
  modules: List(String),
) -> Result(Nil, String)

@external(erlang, "campy_runner_ffi", "validate_modules")
fn runner_validate_modules(
  ebin: String,
  modules: List(String),
) -> Result(Nil, String)

@external(erlang, "campy_runner_test_ffi", "remove_tree")
fn remove_tree(path: String) -> Result(Nil, String)

@external(erlang, "campy_runner_test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "campy_runner_test_ffi", "which")
fn which(module: String) -> String

@external(erlang, "campy_runner_test_ffi", "make_fixture_module")
fn make_fixture_module(dir: String, module: String) -> Result(Nil, String)

@external(erlang, "campy_runner_test_ffi", "reset_order")
fn reset_order() -> Nil

@external(erlang, "campy_runner_test_ffi", "order")
fn load_order() -> List(String)

@external(erlang, "campy_runner_test_ffi", "unload")
fn unload(module: String) -> Nil

fn fast_only() -> Bool {
  getenv("CAMPY_FAST_ONLY") != None
}

// --- Pure tier -------------------------------------------------------------

pub fn status_rendering_test() {
  campy_runner.status_text(campy_runner.Running("cat_cafe", 2, 3, 1))
  |> should.equal("running cat_cafe v2 gen 3 restarts 1")
  campy_runner.status_text(campy_runner.Dead("crash loop"))
  |> should.equal("dead: crash loop")
}

pub fn deliver_filters_by_session_test() {
  let event =
    campy_bridge.NativeEvent(7, 1, "callback:event", "pet-button:clicked")
  routing.accepts(Some(7), event) |> should.be_true
  routing.accepts(Some(8), event) |> should.be_false
  // No session id means a standalone-style single-session VM: forward.
  routing.accepts(None, event) |> should.be_true
  routing.accepts(
    Some(7),
    campy_bridge.NativeEvent(8, 1, "callback:event", "pet-button:clicked"),
  )
  |> should.be_false
}

pub fn deployment_records_failed_update_test() {
  let empty = state_store.BrokerState(current: [], deployments: [])
  let state = deployment.failed(empty, "runner_probe", 2, "boom\nstack trace")
  let assert [first, ..] = state.deployments
  first.app |> should.equal("runner_probe")
  first.version |> should.equal(2)
  first.runner |> should.equal("")
  first.status |> should.equal("reported-failed")
  first.detail |> should.equal("boom")

  let applied = deployment.applied(empty, "runner_probe", 2)
  let assert [first, ..] = applied.deployments
  first.status |> should.equal("applied")
  first.detail |> should.equal("")
}

pub fn module_loading_order_test() {
  let dir = campy_broker.root() <> "/generated/runner/module_order_probe"
  let first = "campy_runner_probe_a"
  let second = "campy_runner_probe_b"
  let assert Ok(Nil) = remove_tree(dir)
  unload(first)
  unload(second)

  make_fixture_module(dir, first) |> should.equal(Ok(Nil))
  make_fixture_module(dir, second) |> should.equal(Ok(Nil))
  reset_order()
  runner_add_path(dir) |> should.equal(Ok(Nil))

  runner_load_modules(dir, [first, second]) |> should.equal(Ok(Nil))
  load_order() |> should.equal([first, second])

  unload(first)
  unload(second)
  reset_order()
  runner_load_modules(dir, [second, first]) |> should.equal(Ok(Nil))
  load_order() |> should.equal([second, first])

  // Validation catches a corrupt beam before any load or purge happens.
  write_file(dir <> "/" <> first <> ".beam", "not a beam")
  |> should.equal(Ok(Nil))
  case runner_validate_modules(dir, [first]) {
    Error(error) ->
      string.contains(error, "cannot load module") |> should.be_true
    Ok(Nil) -> panic as "expected the corrupt beam to be rejected"
  }

  unload(first)
  unload(second)
  remove_tree(dir) |> should.equal(Ok(Nil))
}

// --- Session-dependent tier ------------------------------------------------

pub fn session_lifecycle_test() {
  case has_display() && !fast_only() {
    False -> Nil
    True -> session_lifecycle()
  }
}

fn session_lifecycle() -> Nil {
  let slug = "runner_widgets_fixture"
  let assert Ok(Nil) = remove_tree(campy_broker.artifacts_dir(slug))

  let project = fixture_project()
  let assert Ok(#(v1, _manifest_v1)) = campy_broker.build(project, "widgets")

  let reports = process.new_subject()
  let assert Ok(ref) =
    campy_runner.start(v1, fn(report) { process.send(reports, report) })
  campy_runner.status(ref) |> should.equal(campy_runner.Running(slug, 1, 1, 0))
  await_report(reports, fn(report) {
    case report {
      campy_app.Started(app, 1, _) -> app == slug
      _ -> False
    }
  })

  // One runner per app slug.
  case campy_runner.start(v1, fn(_report) { Nil }) {
    Error("app already running") -> True
    _ -> False
  }
  |> should.be_true

  // v2 is built from a copy of the project with a tweaked handler comment.
  let project = with_handler_comment(project, "runner fixture v2")
  let assert Ok(#(v2, _manifest_v2)) = campy_broker.build(project, "widgets")
  campy_runner.update_code(ref, v2) |> should.equal(Ok(Nil))
  campy_runner.status(ref) |> should.equal(campy_runner.Running(slug, 2, 2, 0))
  string.contains(which("handlers_" <> slug), v2 <> "/ebin")
  |> should.be_true

  // A corrupt beam fails the update while v2 keeps running.
  let project = with_handler_comment(project, "runner fixture v3")
  let assert Ok(#(v3, _manifest_v3)) = campy_broker.build(project, "widgets")
  write_file(v3 <> "/ebin/handlers_" <> slug <> ".beam", "not a beam")
  |> should.equal(Ok(Nil))
  case campy_runner.update_code(ref, v3) {
    Error(error) -> should.be_true(string.length(error) > 0)
    Ok(Nil) -> panic as "expected the corrupt beam update to fail"
  }
  campy_runner.status(ref) |> should.equal(campy_runner.Running(slug, 2, 2, 0))
  string.contains(which("handlers_" <> slug), v2 <> "/ebin")
  |> should.be_true
  state_store.load().deployments
  |> list.any(fn(deployment) {
    deployment.app == slug
    && deployment.version == 3
    && deployment.status == "reported-failed"
  })
  |> should.be_true

  campy_runner.stop(ref)
  await_report(reports, fn(report) {
    case report {
      campy_app.Stopped(_) -> True
      _ -> False
    }
  })
  campy_runner.status(ref) |> should.equal(campy_runner.Dead("stopped"))
}

fn fixture_project() -> project_codec.Project {
  let loaded = load_project()
  let assert Some(module) = project_codec.find_module(loaded, "widgets")
  let module = project_codec.Module(..module, name: "Runner Widgets Fixture")
  let project = project_codec.update_module(loaded, module)
  let assert Ok(saved) = project_codec.save(project, fixture_project_path())
  saved
}

fn with_handler_comment(
  project: project_codec.Project,
  comment: String,
) -> project_codec.Project {
  let assert Some(module) = project_codec.find_module(project, "widgets")
  let module =
    project_codec.Module(
      ..module,
      source: module.source <> "\n// " <> comment <> "\n",
    )
  let project = project_codec.update_module(project, module)
  let assert Ok(saved) = project_codec.save(project, fixture_project_path())
  saved
}

fn fixture_project_path() -> String {
  campy_broker.root() <> "/generated/runner/runner_widgets_fixture.campy"
}

fn load_project() -> project_codec.Project {
  let path = campy_broker.root() <> "/campy.campy"
  case project_codec.load(path) {
    Ok(project) -> project
    Error(error) -> panic as { "cannot load campy.campy: " <> error }
  }
}

fn await_report(
  reports: process.Subject(campy_app.Report),
  predicate: fn(campy_app.Report) -> Bool,
) -> campy_app.Report {
  case process.receive(reports, 10_000) {
    Ok(report) ->
      case predicate(report) {
        True -> report
        False -> await_report(reports, predicate)
      }
    Error(Nil) -> panic as "timed out waiting for a campy_app report"
  }
}
