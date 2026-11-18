//// Distributed tests: the harness boots distribution, starts a real peer
//// node, installs the runtime beams on it, deploys an app, drives it, and
//// receives the replies locally.

import campy_app.{type Msg}
import campy_peer
import campy_runner
import campy_view.{VInt, VText}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  // peer:start requires the calling node to be distributed.
  let assert Ok(Nil) = campy_peer.start_distribution("campy_runner_test_ide")
  gleeunit.main()
}

/// Build a Spec whose document matches campy_app_test's handlers.
fn spec() -> campy_app.Spec {
  campy_app.Spec(
    name: "runner-test",
    module: "campy_app_test",
    document: campy_view.Document(
      schema: 1,
      view: campy_view.node("form", "root")
        |> campy_view.with_props([#("w", VInt(400))])
        |> campy_view.with_children([
          campy_view.node("button", "ok")
            |> campy_view.with_events(["click"]),
          campy_view.node("button", "boom")
            |> campy_view.with_events(["click"]),
        ]),
      extra: [],
    ),
    state_version: 1,
    migrate: None,
  )
}

/// The ebin directories a fresh peer needs: the runner's own build contains
/// every runtime dependency.
fn runtime_dirs() -> List(String) {
  [
    "build/dev/erlang/gleam_stdlib/ebin",
    "build/dev/erlang/gleam_erlang/ebin",
    "build/dev/erlang/gleam_otp/ebin",
    "build/dev/erlang/campy_view/ebin",
    "build/dev/erlang/campy_app/ebin",
    "build/dev/erlang/campy_runner/ebin",
    // The app under test ships with campy_app's test build.
    "../campy_app/build/dev/erlang/campy_app/ebin",
  ]
}

fn start_runner(name: String) -> #(campy_peer.Peer, Subject(campy_app.Reply)) {
  let assert Ok(peer) = campy_peer.start(name)

  // Bootstrap: push the runtime beams over code:load_binary, runner last.
  let assert Ok(count) = campy_peer.deploy_dirs(peer.node, runtime_dirs())
  // gleam_stdlib + erlang + otp + view + app(+test) + runner beams.
  let assert True = count > 40

  // The runner answers on the peer now.
  let assert Ok(status) = campy_peer.call(peer, "campy_runner", "status", [])
  let _ = status

  #(peer, process.new_subject())
}

pub fn deploy_start_and_drive_an_app_on_a_peer_test() {
  let #(peer, reply) = start_runner("campy_runner_deploy")

  // start_app runs on the peer; the spec and the reply subject are plain
  // terms that cross erpc. The dispatch subject's owner is the peer actor.
  let assert Ok(subject) =
    campy_peer.call(peer, "campy_runner", "start_app", [
      wrap(spec()),
      wrap(reply),
    ])
    |> as_subject

  // Drain the actor's initial Version + View pair.
  let assert Ok(campy_app.Version(1)) = process.receive(reply, 5000)
  let assert Ok(campy_app.View(_, 1)) = process.receive(reply, 5000)

  process.send(
    subject,
    campy_app.EventReceived(campy_app.Event(
      control: "ok",
      key: "click",
      value: VText(""),
      generation: 0,
    )),
  )
  let assert Ok(campy_app.Report("ok")) = process.receive(reply, 5000)
  let assert Ok(campy_app.Notified("hello")) = process.receive(reply, 5000)
  let assert Ok(campy_app.View(_, 2)) = process.receive(reply, 5000)

  process.send(subject, campy_app.StopRequest)
  let assert Ok(campy_app.Stopped) = process.receive(reply, 5000)

  campy_peer.stop(peer)
}

pub fn stop_app_via_the_runner_test() {
  let #(peer, reply) = start_runner("campy_runner_stop")

  let assert Ok(subject) =
    campy_peer.call(peer, "campy_runner", "start_app", [
      wrap(spec()),
      wrap(reply),
    ])
    |> as_subject

  // Drain the initial Version + View pair.
  let assert Ok(campy_app.Version(1)) = process.receive(reply, 5000)
  let assert Ok(campy_app.View(_, 1)) = process.receive(reply, 5000)

  // The runner sends StopRequest on this node; the actor replies locally to
  // the IDE's reply subject.
  let assert Ok(Nil) =
    campy_peer.call(peer, "campy_runner", "stop_app", [wrap(subject)])
    |> as_nil
  let assert Ok(campy_app.Stopped) = process.receive(reply, 5000)

  campy_peer.stop(peer)
}

// The transport takes untyped terms (they cross erpc as plain data) and
// returns untyped results; these casts only restore the types.
@external(erlang, "campy_runner_test_ffi", "wrap")
fn wrap(term: a) -> Dynamic

@external(erlang, "campy_runner_test_ffi", "unwrap_result")
fn as_subject(result: Result(Dynamic, String)) -> Result(Subject(Msg), String)

@external(erlang, "campy_runner_test_ffi", "wrap")
fn as_nil(result: Result(Dynamic, String)) -> Result(Nil, String)
