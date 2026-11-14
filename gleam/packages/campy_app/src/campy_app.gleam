//// Supervised host runtime for a designed Campy app.
////
//// A `Config` carries the app identity, the form it was designed from, the
//// module that holds its ABI v1 handlers, and a report callback. `start` opens
//// one bridge session, applies the form's live-preview snapshot, and keeps the
//// app actor under a `gleam_otp` supervisor. Events are pushed in with
//// `deliver`; this actor never polls, so the single poll owner in the VM (the
//// IDE loop today, the runner process later) stays the only `bridge.poll`
//// caller.
////
//// ## P1 state limit
////
//// An app holds no state of its own beyond the form and its applied snapshot.
//// When the actor is restarted after a crash it rebuilds that state from its
//// `Config`; anything a handler might have kept elsewhere is not recovered.
//// Persistent app state is future work.
////
//// Handler ABI v2 (a context argument, so handlers can read or mutate app
//// state) is future work too. ABI v1 handlers are the existing zero-argument
//// `pub fn <control_name>_<event_key>() -> Nil` functions.

import campy_app/handler
import campy_app/preview_apply
import campy_bridge as bridge
import campy_form
import campy_form/live_preview
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string

pub type Report {
  Started(app: String, version: Int, digest: String)
  Applied(app: String)
  CodeUpdated(app: String, version: Int)
  HandlerError(handler: String, reason: String)
  Restarted(app: String, reason: String)
  GaveUp(app: String, reason: String)
  Stopped(app: String)
  Console(line: String)
}

pub type Config {
  Config(
    app: String,
    version: Int,
    digest: String,
    handlers_module: String,
    form: campy_form.Form,
    report: fn(Report) -> Nil,
    restart_limit: Int,
    restart_window_ms: Int,
  )
}

pub const default_restart_limit = 3

pub const default_restart_window_ms = 10_000

// Gleam has no default arguments; callers that want the documented 3 restarts
// per 10 s use this constructor.
pub fn default_config(
  app app: String,
  version version: Int,
  digest digest: String,
  handlers_module handlers_module: String,
  form form: campy_form.Form,
  report report: fn(Report) -> Nil,
) -> Config {
  Config(
    app:,
    version:,
    digest:,
    handlers_module:,
    form:,
    report:,
    restart_limit: default_restart_limit,
    restart_window_ms: default_restart_window_ms,
  )
}

pub opaque type Ref {
  Ref(subject: process.Subject(WatcherMessage))
}

type WatcherMessage {
  DeliverEvent(bridge.NativeEvent)
  ApplySnapshot(campy_form.Form)
  StopApp
  ActorStarting(pid: process.Pid, subject: process.Subject(ActorMessage))
  ActorStartFailed(reason: String)
  ActorStopped
}

type WatchEvent {
  WatchMessage(WatcherMessage)
  WatchDown(process.Down)
}

type ActorMessage {
  ActorDeliver(bridge.NativeEvent)
  ActorApply(campy_form.Form)
  ActorStop
}

type ActorState {
  ActorState(
    config: Config,
    watcher: process.Subject(WatcherMessage),
    form: campy_form.Form,
    session: bridge.Session,
    generation: Int,
  )
}

type ActorInfo {
  ActorInfo(
    pid: process.Pid,
    subject: process.Subject(ActorMessage),
    monitor: process.Monitor,
  )
}

type WatchState {
  WatchState(
    config: Config,
    subject: process.Subject(WatcherMessage),
    supervisor: process.Pid,
    supervisor_monitor: process.Monitor,
    actor: Option(ActorInfo),
    stopping: Bool,
    pending: Option(String),
  )
}

// Start the supervisor and its app actor. The watcher owns lifecycle reports,
// because it is the process that can see both actor and supervisor exits.
pub fn start(config: Config) -> Result(Ref, String) {
  let reply = process.new_subject()
  let watcher = process.spawn(fn() { watcher_entry(config, reply) })
  case process.receive(reply, 5000) {
    Ok(Ok(ref)) -> Ok(ref)
    Ok(Error(reason)) -> Error(reason)
    Error(Nil) -> {
      process.kill(watcher)
      Error("campy_app start timed out")
    }
  }
}

// Push one native event into the app actor's mailbox. The caller (the single
// poll owner) is responsible for routing only this app's session; unknown
// sessions are ignored outside this package.
pub fn deliver(ref: Ref, event: bridge.NativeEvent) -> Nil {
  let Ref(subject) = ref
  process.send(subject, DeliverEvent(event))
}

// Ask the actor to apply a new form snapshot. Fire-and-forget: success arrives
// as an `Applied` report and failure as a `Console` line, leaving the previous
// snapshot live.
pub fn apply_snapshot(ref: Ref, form: campy_form.Form) -> Nil {
  let Ref(subject) = ref
  process.send(subject, ApplySnapshot(form))
}

// Clean stop: close the bridge session, shut the supervisor down, and report
// `Stopped`. Fire-and-forget.
pub fn stop(ref: Ref) -> Nil {
  let Ref(subject) = ref
  process.send(subject, StopApp)
}

// Exact console variant for a report, independent of the app prefix. `Console`
// is raw text by definition.
pub fn report_text(report: Report) -> String {
  case report {
    Started(_, version, _) -> "started v" <> int.to_string(version)
    Applied(_) -> "applied"
    CodeUpdated(_, version) -> "code-updated v" <> int.to_string(version)
    HandlerError(handler, reason) ->
      "handler error: " <> handler <> ": " <> reason
    Restarted(_, reason) -> "restarted: " <> reason
    GaveUp(_, reason) -> "gave up: " <> reason
    Stopped(_) -> "stopped"
    Console(line) -> line
  }
}

// One complete console line: "[<app>] <report variant>".
pub fn report_line(app: String, report: Report) -> String {
  "[" <> app <> "] " <> report_text(report)
}

fn watcher_entry(
  config: Config,
  reply: process.Subject(Result(Ref, String)),
) -> Nil {
  let subject = process.new_subject()
  case start_supervisor(config, subject) {
    Error(reason) -> process.send(reply, Error(reason))
    Ok(supervisor) -> {
      // static_supervisor.start links the supervisor to whoever called it.
      // The watcher observes it through a monitor instead, so a supervisor
      // shutdown must not take the caller's process down with it.
      process.unlink(supervisor)
      let supervisor_monitor = process.monitor(supervisor)
      process.send(reply, Ok(Ref(subject)))
      watcher_loop(WatchState(
        config: config,
        subject: subject,
        supervisor: supervisor,
        supervisor_monitor: supervisor_monitor,
        actor: None,
        stopping: False,
        pending: None,
      ))
    }
  }
}

fn start_supervisor(
  config: Config,
  subject: process.Subject(WatcherMessage),
) -> Result(process.Pid, String) {
  let period = int.max(1, config.restart_window_ms / 1000)
  let child =
    supervision.worker(fn() { start_actor(config, subject) })
    |> supervision.restart(supervision.Transient)
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(config.restart_limit, period)
  |> supervisor.add(child)
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
  |> result.map_error(start_error)
}

fn start_actor(
  config: Config,
  watcher: process.Subject(WatcherMessage),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    initialise_actor(config, watcher, subject)
  })
  |> actor.on_message(handle_actor_message)
  |> actor.start()
}

fn initialise_actor(
  config: Config,
  watcher: process.Subject(WatcherMessage),
  subject: process.Subject(ActorMessage),
) -> Result(actor.Initialised(ActorState, ActorMessage, Nil), String) {
  process.send(watcher, ActorStarting(process.self(), subject))
  case bridge.open_session() {
    Error(error) -> actor_start_failed(watcher, None, error)
    Ok(session) -> {
      case bridge.submit(session, bridge.LoadUi(1, live_preview.to_slint())) {
        Error(error) -> actor_start_failed(watcher, Some(session), error)
        Ok(Nil) -> {
          let snapshot = live_preview.snapshot(config.form)
          case preview_apply.apply(session, snapshot) {
            Error(error) -> actor_start_failed(watcher, Some(session), error)
            Ok(Nil) -> {
              config.report(Started(config.app, config.version, config.digest))
              config.report(Applied(config.app))
              Ok(
                actor.initialised(ActorState(
                  config: config,
                  watcher: watcher,
                  form: config.form,
                  session: session,
                  generation: 1,
                )),
              )
            }
          }
        }
      }
    }
  }
}

fn actor_start_failed(
  watcher: process.Subject(WatcherMessage),
  session: Option(bridge.Session),
  error: String,
) -> Result(actor.Initialised(ActorState, ActorMessage, Nil), String) {
  case session {
    Some(session) -> {
      let _ = bridge.close_session(session)
      Nil
    }
    None -> Nil
  }
  let reason = handler.truncate(error)
  process.send(watcher, ActorStartFailed(reason))
  Error(reason)
}

fn handle_actor_message(
  state: ActorState,
  message: ActorMessage,
) -> actor.Next(ActorState, ActorMessage) {
  case message {
    ActorDeliver(event) -> {
      dispatch_event(state, event)
      actor.continue(state)
    }
    ActorApply(form) -> {
      let snapshot = live_preview.snapshot(form)
      case preview_apply.apply(state.session, snapshot) {
        Ok(Nil) -> {
          state.config.report(Applied(state.config.app))
          actor.continue(
            ActorState(..state, form: form, generation: state.generation + 1),
          )
        }
        Error(error) -> {
          // The old snapshot stays live; the app process must not die for a
          // rejected update.
          state.config.report(Console(error))
          actor.continue(state)
        }
      }
    }
    ActorStop -> {
      let _ = bridge.close_session(state.session)
      process.send(state.watcher, ActorStopped)
      actor.stop()
    }
  }
}

fn dispatch_event(state: ActorState, event: bridge.NativeEvent) {
  case event.kind {
    "callback:event" ->
      case string.split_once(event.payload, ":") {
        Ok(#(control_id, event_key)) ->
          case handler.name_for(state.form, control_id, event_key) {
            None -> Nil
            Some(name) ->
              case handler.apply_handler(state.config.handlers_module, name) {
                Ok(Nil) -> Nil
                Error(reason) ->
                  state.config.report(HandlerError(
                    name,
                    handler.truncate(reason),
                  ))
              }
          }
        Error(Nil) -> Nil
      }
    _ -> Nil
  }
}

fn watcher_loop(state: WatchState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(state.subject, WatchMessage)
    |> process.select_monitors(WatchDown)
  case process.selector_receive(selector, 5000) {
    Ok(WatchMessage(message)) -> handle_watcher_message(state, message)
    Ok(WatchDown(down)) -> handle_watcher_down(state, down)
    Error(Nil) ->
      case state.stopping {
        True -> finish_stop(state)
        False -> watcher_loop(state)
      }
  }
}

fn handle_watcher_message(state: WatchState, message: WatcherMessage) -> Nil {
  case message {
    DeliverEvent(event) -> {
      forward(state, ActorDeliver(event))
      watcher_loop(state)
    }
    ApplySnapshot(form) -> {
      forward(state, ActorApply(form))
      watcher_loop(state)
    }
    StopApp ->
      case state.stopping {
        True -> watcher_loop(state)
        False ->
          case state.actor {
            None -> finish_stop(WatchState(..state, stopping: True))
            Some(info) -> {
              process.send(info.subject, ActorStop)
              watcher_loop(WatchState(..state, stopping: True))
            }
          }
      }
    ActorStarting(pid, subject) -> {
      // A new actor with an old actor still registered means a restart. The
      // monitor's Down usually arrived first with the real reason; if it did
      // not, fall back to a generic label rather than inventing one.
      let pending = case state.actor {
        Some(info) if info.pid != pid -> {
          process.demonitor_process(info.monitor)
          case state.pending {
            Some(reason) -> Some(reason)
            None -> Some("actor restarted")
          }
        }
        _ -> state.pending
      }
      case pending {
        Some(reason) -> state.config.report(Restarted(state.config.app, reason))
        None -> Nil
      }
      let monitor = process.monitor(pid)
      watcher_loop(
        WatchState(
          ..state,
          actor: Some(ActorInfo(pid:, subject:, monitor:)),
          pending: None,
        ),
      )
    }
    ActorStartFailed(reason) ->
      watcher_loop(WatchState(..state, pending: Some(reason)))
    ActorStopped ->
      case state.stopping {
        True -> finish_stop(state)
        False -> finish_stop(WatchState(..state, stopping: True))
      }
  }
}

fn handle_watcher_down(state: WatchState, down: process.Down) -> Nil {
  case down {
    process.ProcessDown(monitor, _, reason)
      if monitor == state.supervisor_monitor
    ->
      case state.stopping {
        True -> finish_stop(state)
        False -> {
          let given_up = case state.pending {
            Some(pending) -> pending
            None -> reason_text(reason)
          }
          state.config.report(GaveUp(state.config.app, given_up))
          Nil
        }
      }
    process.ProcessDown(monitor, _, reason) ->
      case state.actor {
        Some(info) if info.monitor == monitor -> {
          let pending = case state.pending {
            Some(pending) -> Some(pending)
            None -> Some(reason_text(reason))
          }
          watcher_loop(WatchState(..state, actor: None, pending: pending))
        }
        _ -> watcher_loop(state)
      }
    process.PortDown(_, _, _) -> watcher_loop(state)
  }
}

fn finish_stop(state: WatchState) -> Nil {
  terminate_supervisor(state.supervisor)
  state.config.report(Stopped(state.config.app))
  Nil
}

fn forward(state: WatchState, message: ActorMessage) -> Nil {
  case state.actor {
    Some(info) -> process.send(info.subject, message)
    None -> Nil
  }
}

fn reason_text(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(detail) -> string.inspect(detail)
  }
}

fn start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "actor init timed out"
    actor.InitFailed(reason) -> reason
    actor.InitExited(reason) -> "actor init exited: " <> reason_text(reason)
  }
}

@external(erlang, "campy_app_ffi", "terminate_supervisor")
fn terminate_supervisor(supervisor: process.Pid) -> Nil
