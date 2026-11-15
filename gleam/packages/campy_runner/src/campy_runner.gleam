//// The in-VM runner seam: owns app hosting and exposes the interface the IDE
//// (and later a transport) speaks.
////
//// Phase 1 hosts one loaded module set and one `campy_app` bridge session in
//// the caller's VM. The runner never polls; the single poll owner routes
//// native events to `deliver`, which forwards only this app's session.
////
//// Updates follow the appup shape in miniature: read and validate the new
//// artifact, pause delivery, load its modules, then re-apply the current form.
//// `campy_app` drains its mailbox serially, so the `Applied` report that
//// follows is the quiescence barrier (campy_app has no synchronous ping API).
//// A failure before that commit leaves the previous modules, session and
//// version live; the error is returned and the failed deployment recorded.

import campy_app
import campy_bridge
import campy_broker
import campy_broker/state_store
import campy_form
import campy_form/project as project_codec
import campy_manifest.{type Manifest}
import campy_runner/deployment
import campy_runner/routing
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

@external(erlang, "campy_runner_ffi", "add_path")
fn ffi_add_path(ebin: String) -> Result(Nil, String)

@external(erlang, "campy_runner_ffi", "validate_modules")
fn ffi_validate_modules(
  ebin: String,
  modules: List(String),
) -> Result(Nil, String)

@external(erlang, "campy_runner_ffi", "load_modules")
fn ffi_load_modules(ebin: String, modules: List(String)) -> Result(Nil, String)

@external(erlang, "campy_runner_ffi", "claim_app")
fn ffi_claim_app(app: String, pid: process.Pid) -> Bool

@external(erlang, "campy_runner_ffi", "release_app")
fn ffi_release_app(app: String, pid: process.Pid) -> Nil

@external(erlang, "campy_runner_ffi", "resolve_path")
fn ffi_resolve_path(path: String, root: String) -> String

pub type Status {
  Running(app: String, version: Int, generation: Int, restarts: Int)
  Dead(reason: String)
}

pub opaque type Ref {
  Ref(subject: process.Subject(Message))
}

type Message {
  DeliverEvent(campy_bridge.NativeEvent)
  ApplySnapshot(campy_form.Form, reply: process.Subject(Result(Nil, String)))
  UpdateCode(artifact_dir: String, reply: process.Subject(Result(Nil, String)))
  StatusQuery(reply: process.Subject(Status))
  AppReport(campy_app.Report)
  StopRunner
}

type Pending {
  PendingUpdate(
    artifact_dir: String,
    version: Int,
    digest: String,
    reply: process.Subject(Result(Nil, String)),
  )
  PendingSnapshot(
    form: campy_form.Form,
    reply: process.Subject(Result(Nil, String)),
  )
}

type State {
  State(
    subject: process.Subject(Message),
    report: fn(campy_app.Report) -> Nil,
    app_ref: campy_app.Ref,
    app: String,
    version: Int,
    digest: String,
    artifact_dir: String,
    form: campy_form.Form,
    session: Option(Int),
    generation: Int,
    restarts: Int,
    status: Status,
    pending: Option(Pending),
    paused: Bool,
    stopping: Bool,
  )
}

/// Start hosting the artifact. Reads its manifest, adds its `ebin` to the code
/// path, loads every listed module, reopens the form from the manifest's
/// provenance, then starts `campy_app`. One runner per app slug; a second
/// start while that app runs returns `Error("app already running")`.
pub fn start(
  artifact_dir: String,
  report: fn(campy_app.Report) -> Nil,
) -> Result(Ref, String) {
  let reply = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() { runner_entry(artifact_dir, report, reply) })
  case process.receive(reply, 30_000) {
    Ok(Ok(ref)) -> Ok(ref)
    Ok(Error(error)) -> Error(error)
    Error(Nil) -> Error("campy_runner start timed out")
  }
}

/// Fast path: apply a form snapshot without a build. Waits for the `Applied`
/// barrier so an error is reported to the caller; the previous snapshot stays
/// live on failure.
pub fn apply_snapshot(ref: Ref, form: campy_form.Form) -> Result(Nil, String) {
  let Ref(subject) = ref
  case request(subject, fn(reply) { ApplySnapshot(form, reply) }) {
    Ok(result) -> result
    Error(error) -> Error(error)
  }
}

/// Host a newly built artifact: validate and load its modules, pause delivery,
/// re-apply the current form, and commit on the `Applied` barrier. Failed
/// updates keep the old modules and version live and record a failed
/// deployment.
pub fn update_code(ref: Ref, artifact_dir: String) -> Result(Nil, String) {
  let Ref(subject) = ref
  case request(subject, fn(reply) { UpdateCode(artifact_dir, reply) }) {
    Ok(result) -> result
    Error(error) -> Error(error)
  }
}

/// Forward one native event if it belongs to this app's bridge session.
pub fn deliver(ref: Ref, event: campy_bridge.NativeEvent) -> Nil {
  let Ref(subject) = ref
  process.send(subject, DeliverEvent(event))
}

pub fn status(ref: Ref) -> Status {
  let Ref(subject) = ref
  case request(subject, StatusQuery) {
    Ok(status) -> status
    Error(reason) -> Dead(reason)
  }
}

pub fn stop(ref: Ref) -> Nil {
  let Ref(subject) = ref
  process.send(subject, StopRunner)
}

/// Console rendering used by tests and host logs.
pub fn status_text(status: Status) -> String {
  case status {
    Running(app, version, generation, restarts) ->
      "running "
      <> app
      <> " v"
      <> int.to_string(version)
      <> " gen "
      <> int.to_string(generation)
      <> " restarts "
      <> int.to_string(restarts)
    Dead(reason) -> "dead: " <> reason
  }
}

fn request(
  subject: process.Subject(message),
  make_request: fn(process.Subject(reply)) -> message,
) -> Result(reply, String) {
  case process.subject_owner(subject) {
    Error(_) -> Error("runner is not running")
    Ok(pid) ->
      case process.is_alive(pid) {
        False -> Error("runner is not running")
        True -> {
          let reply = process.new_subject()
          process.send(subject, make_request(reply))
          case process.receive(reply, 10_000) {
            Ok(value) -> Ok(value)
            Error(Nil) -> Error("runner timed out")
          }
        }
      }
  }
}

fn runner_entry(
  artifact_dir: String,
  report: fn(campy_app.Report) -> Nil,
  reply: process.Subject(Result(Ref, String)),
) -> Nil {
  case initialise(artifact_dir, report) {
    Error(error) -> process.send(reply, Error(error))
    Ok(state) -> {
      let State(subject, ..) = state
      process.send(reply, Ok(Ref(subject)))
      loop(state)
    }
  }
}

fn initialise(
  artifact_dir: String,
  report: fn(campy_app.Report) -> Nil,
) -> Result(State, String) {
  use manifest <- result.try(load_manifest(artifact_dir))
  let pid = process.self()
  case ffi_claim_app(manifest.app, pid) {
    False -> Error("app already running")
    True ->
      case prepare(manifest, artifact_dir, report) {
        Ok(state) -> Ok(state)
        Error(error) -> {
          ffi_release_app(manifest.app, pid)
          Error(error)
        }
      }
  }
}

fn prepare(
  manifest: Manifest,
  artifact_dir: String,
  report: fn(campy_app.Report) -> Nil,
) -> Result(State, String) {
  use form <- result.try(load_form(manifest))
  let ebin = artifact_dir <> "/ebin"
  use _ <- result.try(ffi_add_path(ebin))
  use _ <- result.try(ffi_validate_modules(ebin, manifest.modules))
  use _ <- result.try(ffi_load_modules(ebin, manifest.modules))
  let subject = process.new_subject()
  let config =
    campy_app.default_config(
      app: manifest.app,
      version: manifest.version,
      digest: manifest.content_digest,
      handlers_module: handlers_module(manifest),
      form: form,
      report: fn(app_report) { process.send(subject, AppReport(app_report)) },
    )
  case campy_app.start(config) {
    Error(error) -> Error(error)
    Ok(app_ref) -> {
      let session = case campy_app.session_id(app_ref) {
        Ok(id) -> Some(id)
        Error(_) -> None
      }
      Ok(State(
        subject: subject,
        report: report,
        app_ref: app_ref,
        app: manifest.app,
        version: manifest.version,
        digest: manifest.content_digest,
        artifact_dir: artifact_dir,
        form: form,
        session: session,
        generation: 1,
        restarts: 0,
        status: Running(manifest.app, manifest.version, 1, 0),
        pending: None,
        paused: False,
        stopping: False,
      ))
    }
  }
}

fn load_manifest(artifact_dir: String) -> Result(Manifest, String) {
  campy_manifest.load(artifact_dir <> "/manifest.campy")
}

fn load_form(manifest: Manifest) -> Result(campy_form.Form, String) {
  let path = ffi_resolve_path(manifest.project_path, campy_broker.root())
  use project <- result.try(project_codec.load(path))
  case project_codec.find_module(project, manifest.module_id) {
    Some(module) -> Ok(module.form)
    None -> Error("unknown module: " <> manifest.module_id)
  }
}

fn handlers_module(manifest: Manifest) -> String {
  case
    list.find(manifest.modules, fn(module) {
      string.starts_with(module, "handlers_")
    })
  {
    Ok(module) -> module
    Error(_) -> "handlers_" <> manifest.app
  }
}

fn loop(state: State) -> Nil {
  case process.receive(state.subject, 5000) {
    Ok(message) ->
      case handle(state, message) {
        Some(next) -> loop(next)
        None -> Nil
      }
    Error(Nil) ->
      case state.stopping {
        True -> Nil
        False -> loop(state)
      }
  }
}

fn handle(state: State, message: Message) -> Option(State) {
  case message {
    DeliverEvent(event) -> {
      case state.status {
        Dead(_) -> Nil
        Running(_, _, _, _) ->
          case state.paused {
            False ->
              case routing.accepts(state.session, event) {
                True -> campy_app.deliver(state.app_ref, event)
                False -> Nil
              }
            True -> Nil
          }
      }
      Some(state)
    }
    ApplySnapshot(form, reply) ->
      case state.status {
        Dead(_) -> {
          process.send(reply, Error("app is not running"))
          Some(state)
        }
        Running(_, _, _, _) ->
          case state.pending {
            Some(_) -> {
              process.send(reply, Error("app is busy"))
              Some(state)
            }
            None -> {
              campy_app.apply_snapshot(state.app_ref, form)
              Some(State(..state, pending: Some(PendingSnapshot(form, reply))))
            }
          }
      }
    UpdateCode(artifact_dir, reply) ->
      case state.status {
        Dead(_) -> {
          process.send(reply, Error("app is not running"))
          Some(state)
        }
        Running(_, _, _, _) ->
          case state.pending {
            Some(_) -> {
              process.send(reply, Error("app is busy"))
              Some(state)
            }
            None -> Some(start_update(state, artifact_dir, reply))
          }
      }
    StatusQuery(reply) -> {
      process.send(reply, state.status)
      Some(state)
    }
    AppReport(report) -> {
      state.report(report)
      Some(handle_app_report(state, report))
    }
    StopRunner -> {
      let next = case state.pending {
        Some(pending) -> fail_pending(state, pending, "app stopped")
        None -> state
      }
      ffi_release_app(next.app, process.self())
      case next.status {
        Dead(_) -> None
        Running(_, _, _, _) -> {
          campy_app.stop(next.app_ref)
          Some(State(..next, stopping: True))
        }
      }
    }
  }
}

fn start_update(
  state: State,
  artifact_dir: String,
  reply: process.Subject(Result(Nil, String)),
) -> State {
  case load_manifest(artifact_dir) {
    Error(error) -> {
      // Without a manifest there is no version to record; the old deployment
      // stays exactly as it was.
      process.send(reply, Error(error))
      state
    }
    Ok(manifest) -> {
      let ebin = artifact_dir <> "/ebin"
      let prepared =
        result.try(ffi_add_path(ebin), fn(_) {
          ffi_validate_modules(ebin, manifest.modules)
        })
      case prepared {
        Error(error) -> {
          record_failure(state.app, manifest.version, error)
          process.send(reply, Error(error))
          state
        }
        Ok(Nil) -> {
          let paused = State(..state, paused: True)
          case ffi_load_modules(ebin, manifest.modules) {
            Error(error) -> {
              record_failure(state.app, manifest.version, error)
              process.send(reply, Error(error))
              State(..paused, paused: False)
            }
            Ok(Nil) -> {
              campy_app.apply_snapshot(state.app_ref, state.form)
              State(
                ..paused,
                pending: Some(PendingUpdate(
                  artifact_dir,
                  manifest.version,
                  manifest.content_digest,
                  reply,
                )),
              )
            }
          }
        }
      }
    }
  }
}

fn handle_app_report(state: State, report: campy_app.Report) -> State {
  case report {
    campy_app.Started(_, version, digest) -> {
      let status = Running(state.app, version, state.generation, state.restarts)
      State(..state, version: version, digest: digest, status: status)
    }
    campy_app.Applied(_) -> commit_applied(state)
    campy_app.Console(line) ->
      case state.pending {
        Some(pending) -> fail_pending(state, pending, line)
        None -> state
      }
    campy_app.Restarted(_, _) -> {
      let restarts = state.restarts + 1
      let session = case campy_app.session_id(state.app_ref) {
        Ok(id) -> Some(id)
        Error(_) -> None
      }
      State(
        ..state,
        restarts: restarts,
        session: session,
        status: Running(state.app, state.version, state.generation, restarts),
      )
    }
    campy_app.GaveUp(_, reason) -> {
      let next = case state.pending {
        Some(pending) -> fail_pending(state, pending, "app gave up: " <> reason)
        None -> state
      }
      ffi_release_app(next.app, process.self())
      State(..next, status: Dead(reason), pending: None, paused: False)
    }
    campy_app.Stopped(_) -> {
      let next = case state.pending {
        Some(pending) -> fail_pending(state, pending, "app stopped")
        None -> state
      }
      ffi_release_app(next.app, process.self())
      State(..next, status: Dead("stopped"), pending: None, paused: False)
    }
    campy_app.CodeUpdated(_, _) -> state
    campy_app.HandlerError(_, _) -> state
  }
}

fn commit_applied(state: State) -> State {
  case state.pending {
    None -> state
    Some(PendingSnapshot(form, reply)) -> {
      process.send(reply, Ok(Nil))
      State(
        ..state,
        form: form,
        generation: state.generation + 1,
        pending: None,
      )
    }
    Some(PendingUpdate(artifact_dir, version, digest, reply)) -> {
      record_success(state.app, version)
      state.report(campy_app.CodeUpdated(state.app, version))
      process.send(reply, Ok(Nil))
      let generation = state.generation + 1
      State(
        ..state,
        artifact_dir: artifact_dir,
        version: version,
        digest: digest,
        generation: generation,
        pending: None,
        paused: False,
        status: Running(state.app, version, generation, state.restarts),
      )
    }
  }
}

fn fail_pending(state: State, pending: Pending, error: String) -> State {
  case pending {
    PendingSnapshot(_, reply) -> {
      process.send(reply, Error(error))
      State(..state, pending: None)
    }
    PendingUpdate(_, version, _, reply) -> {
      record_failure(state.app, version, error)
      process.send(reply, Error(error))
      State(..state, pending: None, paused: False)
    }
  }
}

fn record_success(app: String, version: Int) {
  let next = deployment.applied(state_store.load(), app, version)
  let _ = state_store.save(next)
  Nil
}

fn record_failure(app: String, version: Int, detail: String) {
  let next = deployment.failed(state_store.load(), app, version, detail)
  let _ = state_store.save(next)
  Nil
}
