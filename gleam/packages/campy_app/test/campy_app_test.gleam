//// The test module doubles as the ABI v2 app under test: `init/0`, `view/1`,
//// and the `<control>_<event>` handlers live here, so `function_exported`
//// resolves against a real loaded module.

import campy_app.{
  type Effect, type Event, type Spec, Event, EventReceived, Log, Notify,
  SnapshotRequest, Stop, StopRequest, Upgrade,
}

import campy_view.{type Document, VInt, VText}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub type State {
  State(count: Int)
}

pub fn init() -> State {
  State(0)
}

pub fn view(_state: State) -> Document {
  campy_view.Document(
    schema: 1,
    view: campy_view.node("form", "root")
      |> campy_view.with_props([#("title", VText("Test")), #("w", VInt(400))])
      |> campy_view.with_children([
        campy_view.node("button", "ok")
          |> campy_view.with_props([#("text", VText("Ok"))])
          |> campy_view.with_events(["click"]),
        campy_view.node("button", "boom")
          |> campy_view.with_props([#("text", VText("Boom"))])
          |> campy_view.with_events(["click"]),
        campy_view.node("button", "halt")
          |> campy_view.with_props([#("text", VText("Halt"))])
          |> campy_view.with_events(["click"]),
      ]),
    extra: [],
  )
}

pub fn ok_click(state: State, _event: Event) -> #(State, List(Effect)) {
  #(State(state.count + 1), [Log("ok"), Notify("hello")])
}

pub fn boom_click(_state: State, _event: Event) -> #(State, List(Effect)) {
  panic as "boom"
}

pub fn halt_click(state: State, _event: Event) -> #(State, List(Effect)) {
  #(state, [Stop])
}

pub fn migrate(state: State, _from: Int) -> State {
  State(state.count + 100)
}

// --- fixtures --------------------------------------------------------------

fn document() -> Document {
  view(init())
}

fn spec() -> Spec {
  campy_app.Spec(
    name: "test",
    module: "campy_app_test",
    document: document(),
    state_version: 1,
    migrate: None,
  )
}

type Harness {
  Harness(
    reply: process.Subject(campy_app.Reply),
    subject: Subject(campy_app.Msg),
  )
}

fn start() -> Harness {
  let reply = process.new_subject()
  let assert Ok(subject) = campy_app.start(spec(), reply)
  Harness(reply, subject)
}

/// Drain the initial Version + View pair.
fn drain_initial(h: Harness) {
  let assert Ok(campy_app.Version(1)) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 1)) = process.receive(h.reply, 1000)
}

fn click(control: String, key: String) -> campy_app.Msg {
  EventReceived(Event(control, key, VText(""), 1))
}

// --- tests -----------------------------------------------------------------

pub fn start_publishes_version_and_initial_view_test() {
  let h = start()
  drain_initial(h)
}

pub fn event_dispatches_and_publishes_the_next_generation_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("ok", "click"))

  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)
}

pub fn missing_handler_is_a_no_op_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("nope", "click"))

  // No reply at all; the next handled event still advances 1 -> 2.
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)
}

pub fn undeclared_event_is_ignored_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("ok", "paint"))
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)
}

pub fn crashing_handler_is_contained_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("boom", "click"))

  let assert Ok(campy_app.Report(text)) = process.receive(h.reply, 1000)
  let assert True = string_contains(text, "HandlerError")
  let assert True = string_contains(text, "boom")

  // The actor is still alive and the state is unchanged (count 0 -> 1).
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)
}

pub fn stop_effect_stops_the_app_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("halt", "click"))
  let assert Ok(campy_app.Stopped) = process.receive(h.reply, 1000)
}

pub fn stop_message_replies_stopped_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, StopRequest)
  let assert Ok(campy_app.Stopped) = process.receive(h.reply, 1000)
}

pub fn upgrade_runs_migrate_and_republishes_test() {
  // ok once: count 0 -> 1.
  let h = start()
  drain_initial(h)
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)

  process.send(h.subject, Upgrade("campy_app_test", 1, 2))
  let assert Ok(campy_app.Version(2)) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 3)) = process.receive(h.reply, 1000)

  // The migrated state carried count + 100.
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.View(_, 4)) = process.receive(h.reply, 1000)

  let assert campy_app.Snapshot(state, 2) = snapshot(h)
  let assert Ok(count) = decode_count(state)
  count |> should.equal(102)
}

pub fn upgrade_with_the_running_version_is_a_no_op_test() {
  let h = start()
  drain_initial(h)
  process.send(h.subject, Upgrade("campy_app_test", 1, 1))
  process.send(h.subject, click("ok", "click"))
  let assert Ok(campy_app.Report("ok")) = process.receive(h.reply, 1000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(h.reply, 1000)
  // No migrate ran and no upgrade view: the handled event published gen 2.
  let assert Ok(campy_app.View(_, 2)) = process.receive(h.reply, 1000)
}

pub fn snapshot_reports_state_and_version_test() {
  let h = start()
  drain_initial(h)
  let assert campy_app.Snapshot(_, 1) = snapshot(h)
}

pub fn handler_name_matches_the_authoring_rule_test() {
  campy_app.handler_name("ok", "click") |> should.equal("ok_click")
}

// --- helpers ---------------------------------------------------------------

fn snapshot(h: Harness) -> campy_app.Snapshot {
  // The actor answers on the subject carried by the request, not the app's
  // reply channel.
  let me = process.new_subject()
  process.send(h.subject, SnapshotRequest(me))
  let assert Ok(snapshot) = process.receive(me, 1000)
  snapshot
}

@external(erlang, "campy_app_test_ffi", "decode_count")
fn decode_count(state: Dynamic) -> Result(Int, Nil)

fn string_contains(haystack: String, needle: String) -> Bool {
  case list.contains(string.split(haystack, " "), needle) {
    True -> True
    False -> {
      // substring check for multi-word needles like "HandlerError"
      string.contains(haystack, needle)
    }
  }
}
