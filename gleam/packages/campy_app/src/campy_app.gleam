//// ABI v2 application actor (ADR 0004).
////
//// An app is state plus handlers: `init/0`, `view/1`, and one
//// `<control>_<event>` handler per declared event, each with the signature
////
////     pub fn ok_click(state: State, event: Event) -> #(State, List(Effect))
////
//// The actor owns the app state, dispatches events by handler name resolved
//// from the form document, and publishes the whole form document with a
//// generation after every applied event so clients can diff. A missing
//// handler is a no-op; a raising handler becomes a contained report. Effects
//// are `Log`, `Notify`, and `Stop`. There is no polling and no bridge: the
//// owner sends `Msg`s and receives `Reply`s on a subject.

import campy_view.{type Document, type Node, type Value}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type Event {
  Event(control: String, key: String, value: Value, generation: Int)
}

pub type Effect {
  Log(text: String)
  Notify(text: String)
  Stop
}

pub type Reply {
  /// The whole form document with the view generation it was derived from.
  View(document: Document, generation: Int)
  /// A console line: `Log` effects and contained handler errors.
  Report(text: String)
  /// Delivery of the app's `Notify` effect (distinct from the effect itself,
  /// whose constructor name must stay unambiguous for user handlers).
  Notified(text: String)
  /// The ABI v2 `state_version` after a (re)start or upgrade.
  Version(Int)
  Stopped
}

pub type Snapshot {
  Snapshot(state: Dynamic, version: Int)
}

/// A running app instance, recorded by the IDE model: the app's dispatch
/// subject plus the reply channel the shell polls.
pub type Running {
  Running(
    name: String,
    slug: String,
    module: String,
    dispatch: Subject(Msg),
    reply: Subject(Reply),
  )
}

/// The runtime's view of an installed app. `module` implements `init/0`,
/// `view/1`, and the `<control>_<event>` handlers; `document` is the form used
/// to resolve handler names. `migrate` runs on upgrade (T3.4) when the carried
/// version differs from `state_version`.
pub type Spec {
  Spec(
    name: String,
    module: String,
    document: Document,
    state_version: Int,
    migrate: Option(fn(Dynamic, Int) -> Dynamic),
  )
}

pub type Msg {
  EventReceived(Event)
  /// Install code from `module` and run its `migrate/2` when `from` differs
  /// from the running version. The actor passes its current state.
  Upgrade(module: String, from: Int, version: Int)
  SnapshotRequest(reply: Subject(Snapshot))
  StopRequest
}

type Data {
  Data(spec: Spec, state: Dynamic, generation: Int, reply: Subject(Reply))
}

@external(erlang, "campy_app_ffi", "init_of")
fn init_of(module: String) -> Result(Dynamic, String)

@external(erlang, "campy_app_ffi", "view_of")
fn view_of(module: String, state: Dynamic) -> Result(Document, String)

@external(erlang, "campy_app_ffi", "dispatch")
fn dispatch(
  module: String,
  fun: String,
  state: Dynamic,
  event: Event,
) -> Result(#(Dynamic, List(Effect)), String)

@external(erlang, "campy_app_ffi", "exported")
fn exported(module: String, fun: String, arity: Int) -> Bool

@external(erlang, "campy_app_ffi", "migrate_of")
fn migrate_of(
  module: String,
  state: Dynamic,
  from: Int,
) -> Result(Dynamic, String)

/// `<control>_<event>`, the ABI v2 handler name. The authoring side keeps the
/// same rule in `campy_project.handler_name`; the runtime stays dependency-
/// light and repeats the rule here, asserted by tests.
pub fn handler_name(control: String, key: String) -> String {
  control <> "_" <> key
}

/// Start the app actor. The initialiser runs `init/0` and `view/1` in the
/// app module, publishes `Version` and the first `View`, and fails `start`
/// when either is missing or raises.
pub fn start(
  spec: Spec,
  reply: Subject(Reply),
) -> Result(Subject(Msg), String) {
  let initialised = fn(subject: Subject(Msg)) {
    case init_of(spec.module) {
      Error(reason) ->
        Error("app " <> spec.name <> ": init/0 failed: " <> reason)
      Ok(state) ->
        case view_of(spec.module, state) {
          Error(reason) ->
            Error("app " <> spec.name <> ": view/1 failed: " <> reason)
          Ok(document) -> {
            process.send(reply, Version(spec.state_version))
            process.send(reply, View(document, 1))
            actor.initialised(Data(spec, state, 1, reply))
            |> actor.returning(subject)
            |> Ok
          }
        }
    }
  }

  actor.new_with_initialiser(5000, initialised)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("app actor failed to start")
}

fn handle(data: Data, msg: Msg) -> actor.Next(Data, Msg) {
  case msg {
    EventReceived(event) -> handle_event(data, event)
    Upgrade(module, from, version) ->
      handle_upgrade(data, module, from, version)
    SnapshotRequest(snapshot) -> {
      process.send(snapshot, Snapshot(data.state, data.spec.state_version))
      actor.continue(data)
    }
    StopRequest -> {
      process.send(data.reply, Stopped)
      actor.stop()
    }
  }
}

fn handle_event(data: Data, event: Event) -> actor.Next(Data, Msg) {
  case resolve(data.spec.document.view, event.control, event.key) {
    Error(Nil) ->
      // Unknown control or undeclared event: a no-op, per ABI v2.
      actor.continue(data)
    Ok(name) ->
      case exported(data.spec.module, name, 2) {
        False -> {
          actor.continue(data)
        }
        True ->
          case dispatch(data.spec.module, name, data.state, event) {
            Error(reason) -> {
              process.send(
                data.reply,
                Report(
                  "HandlerError "
                  <> data.spec.module
                  <> "."
                  <> name
                  <> ": "
                  <> reason,
                ),
              )
              actor.continue(data)
            }
            Ok(#(state, effects)) -> {
              let data = Data(..data, state: state)
              case run_effects(data, effects) {
                EffectsDone(data) -> publish(data)
                EffectsStop(_) -> actor.stop()
              }
            }
          }
      }
  }
}

type Effects {
  EffectsDone(data: Data)
  EffectsStop(data: Data)
}

fn run_effects(data: Data, effects: List(Effect)) -> Effects {
  case effects {
    [] -> EffectsDone(data)
    [Log(text), ..rest] -> {
      process.send(data.reply, Report(text))
      run_effects(data, rest)
    }
    [Notify(text), ..rest] -> {
      process.send(data.reply, Notified(text))
      run_effects(data, rest)
    }
    [Stop, ..] -> {
      process.send(data.reply, Stopped)
      EffectsStop(data)
    }
  }
}

/// Publish the view derived from the current state with the next generation.
fn publish(data: Data) -> actor.Next(Data, Msg) {
  case view_of(data.spec.module, data.state) {
    Error(reason) -> {
      process.send(data.reply, Report("view/1 failed: " <> reason))
      actor.continue(data)
    }
    Ok(document) -> {
      let generation = data.generation + 1
      process.send(data.reply, View(document, generation))
      actor.continue(Data(..data, generation: generation))
    }
  }
}

fn handle_upgrade(
  data: Data,
  module: String,
  from: Int,
  version: Int,
) -> actor.Next(Data, Msg) {
  case from == version {
    True -> actor.continue(data)
    False -> {
      let state = case data.spec.migrate {
        Some(migrate) ->
          case migrate_of(module, data.state, from) {
            Ok(migrated) -> migrated
            Error(_) ->
              // migrate/2 is optional; fall back to the caller-provided
              // closure for the in-VM path.
              migrate(data.state, from)
          }
        None ->
          case migrate_of(module, data.state, from) {
            Ok(migrated) -> migrated
            Error(_) -> data.state
          }
      }
      let spec = Spec(..data.spec, module: module, state_version: version)
      let data = Data(..data, spec: spec, state: state)
      process.send(data.reply, Version(version))
      publish(data)
    }
  }
}

/// Resolve the handler name: the control must exist in the form and must have
/// declared the event key.
fn resolve(root: Node, control: String, key: String) -> Result(String, Nil) {
  case find_node(root, control) {
    Error(Nil) -> Error(Nil)
    Ok(node) ->
      case list.contains(node.events, key) {
        True -> Ok(handler_name(control, key))
        False -> Error(Nil)
      }
  }
}

fn find_node(node: Node, id: String) -> Result(Node, Nil) {
  case node.id == id {
    True -> Ok(node)
    False ->
      case
        list.find(node.children, fn(child) {
          find_node(child, id) != Error(Nil)
        })
      {
        Ok(child) -> find_node(child, id)
        Error(Nil) -> Error(Nil)
      }
  }
}
