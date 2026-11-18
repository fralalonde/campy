//// Peer BEAM nodes (M4, ADR 0005). A peer is a real distributed Erlang node
//// spawned with OTP's `peer` module: the IDE talks to it over the standard
//// port protocol, so the IDE itself does not have to be distributed to run
//// one. Each peer will own a `campy_runner` (T4.2) that loads compiled apps
//// and starts/stops them on behalf of the IDE.
////
//// Node names follow `shortnames`: `Name@Host` on the local machine.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/result

/// A started peer: the supervisor pid (stop it with `stop`) and the node
/// name as an atom-shaped string, e.g. `greeter@workstation`.
pub type Peer {
  Peer(pid: Pid, node: String)
}

@external(erlang, "campy_peer_ffi", "start")
fn ffi_start(name: String) -> Result(#(Pid, String), String)

@external(erlang, "campy_peer_ffi", "stop")
fn ffi_stop(pid: Pid) -> Nil

@external(erlang, "campy_peer_ffi", "call")
fn ffi_call(
  node: String,
  module: String,
  function: String,
  args: List(Dynamic),
) -> Result(Dynamic, String)

@external(erlang, "campy_peer_ffi", "ping")
fn ffi_ping(node: String) -> Result(String, String)

/// Start distribution on the current node with a short name, so peers can
/// report back to the IDE over the net kernel (T4.2). Calling it when
/// distribution is already on (or when it is on by another name) is fine;
/// the error text carries the reason otherwise.
@external(erlang, "campy_peer_ffi", "start_distribution")
pub fn start_distribution(name: String) -> Result(Nil, String)

/// The current node's name, or an empty string when distribution is off.
@external(erlang, "campy_peer_ffi", "this_node")
pub fn this_node() -> String

/// Bootstrap deploy: read every beam under a local directory and load it on
/// the peer with `code:load_binary`. This is the transport that installs the
/// runner itself before any runner call is possible. Returns the count.
@external(erlang, "campy_peer_ffi", "deploy_dir")
pub fn deploy_dir(node: String, dir: String) -> Result(Int, String)

/// Deploy every beam directory in order.
pub fn deploy_dirs(node: String, dirs: List(String)) -> Result(Int, String) {
  list.fold(dirs, Ok(0), fn(acc, dir) {
    case acc {
      Error(reason) -> Error(reason)
      Ok(total) ->
        case deploy_dir(node, dir) {
          Ok(count) -> Ok(total + count)
          Error(reason) -> Error(reason)
        }
    }
  })
}

/// Start a peer node named `name`. The name is the short (host-less) part;
/// the full node is `name@<local host>`. Fails when the name is empty or the
/// node cannot boot.
pub fn start(name: String) -> Result(Peer, String) {
  case name {
    "" -> Error("campy_peer: node name must not be empty")
    _ ->
      ffi_start(name)
      |> result.map(fn(started) {
        let #(pid, node) = started
        Peer(pid, node)
      })
  }
}

/// Stop a peer node and wait for its teardown.
pub fn stop(peer: Peer) -> Nil {
  ffi_stop(peer.pid)
}

/// A round trip to the peer: asks it for its own node name. Cheap, and
/// doubles as a health check. Waits for the peer's net kernel to accept
/// connections (up to ~2 s) before giving up.
pub fn ping(peer: Peer) -> Result(String, String) {
  ffi_ping(peer.node)
}

/// Run a function on the peer over Erlang distribution. Low level;
/// `campy_runner` (T4.2) wraps it.
pub fn call(
  peer: Peer,
  module: String,
  function: String,
  args: List(Dynamic),
) -> Result(Dynamic, String) {
  ffi_call(peer.node, module, function, args)
}

/// True when every peer answers a round trip.
pub fn healthy(peers: List(Peer)) -> Bool {
  list.all(peers, fn(peer) {
    case ping(peer) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}
