//// The control surface that runs on a peer node (M4, ADR 0005). The IDE
//// loads this module's beam plus the runtime beams on the peer via
//// `rpc:call(Node, campy_runner, install, ...)`, then drives the app actor
//// remotely: `start_app` boots a `campy_app` actor on the peer, events go
//// through the dispatch subject (its owner lives on the peer), and reports
//// come back through the reply subject the IDE created.
////
//// Every function is meant to be called ON the peer node. `campy_peer.call`
//// is the transport.

import campy_app.{type Msg, type Spec}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list
import gleam/result

/// Install compiled beams on the peer: `code:load_binary` each
/// `#(module_name, binary)` in order. Returns the count on success; a failed
/// module aborts the run and reports which one.
@external(erlang, "campy_runner_ffi", "install")
pub fn install(beams: List(#(String, Dynamic))) -> Result(Int, String)

/// Start the app actor on this node. The dispatch subject's owner is the
/// actor here; the IDE sends events to it over distribution and receives
/// replies on its own reply subject.
@external(erlang, "campy_runner_ffi", "unlink_owner")
pub fn unlink_owner(subject: process.Subject(a)) -> Nil

/// Start the app actor on this node. The dispatch subject's owner is the
/// actor here; the IDE sends events to it over distribution and receives
/// replies on its own reply subject. The actor is unlinked from the caller:
/// an `rpc` caller is transient, and its exit must not take the app down.
pub fn start_app(
  spec: Spec,
  reply: process.Subject(campy_app.Reply),
) -> Result(process.Subject(campy_app.Msg), String) {
  case campy_app.start(spec, reply) {
    Ok(subject) -> {
      unlink_owner(subject)
      Ok(subject)
    }
    Error(reason) -> Error(reason)
  }
}

/// Tell the running app actor to stop (via its dispatch subject).
pub fn stop_app(subject: process.Subject(campy_app.Msg)) -> Nil {
  process.send(subject, campy_app.StopRequest)
}

/// The code versions of the campy modules loaded on this node, for the node
/// manager's version column.
@external(erlang, "campy_runner_ffi", "loaded_versions")
pub fn status() -> List(#(String, String))

/// Run `init/0` + `view/1` on an installed app module without starting an
/// actor — the debug viewer's state/preview bootstrap.
@external(erlang, "campy_runner_ffi", "init_of")
pub fn init_of(module: String) -> Result(Dynamic, String)

/// Purge and delete an installed module (rollback).
@external(erlang, "campy_runner_ffi", "purge")
pub fn purge(module: String) -> Nil

/// Helper for the IDE: build the `#(name, binary)` pairs for a directory of
/// beams, filtered by module name prefix.
@external(erlang, "campy_runner_ffi", "beams_of_dir")
pub fn beams_of_dir(dir: String) -> List(#(String, Dynamic))

/// Install every beam found under `dir`, returning the count.
pub fn install_dir(dir: String) -> Result(Int, String) {
  result.map(install(beams_of_dir(dir)), fn(count) { count })
}

/// Install several directories in order.
pub fn install_dirs(dirs: List(String)) -> Result(Int, String) {
  let installed =
    list.fold(dirs, Ok(0), fn(acc, dir) {
      case acc {
        Error(reason) -> Error(reason)
        Ok(total) ->
          case install_dir(dir) {
            Ok(count) -> Ok(total + count)
            Error(reason) -> Error(reason)
          }
      }
    })
  installed
}
