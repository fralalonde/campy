//// Peer node tests. Each test spawns a real (tiny) peer node; the IDE node
//// itself stays undistributed because the port protocol needs no net kernel.

import campy_peer
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  // peer:start requires the calling node to be distributed (not_alive
  // otherwise), so the harness boots the net kernel first.
  let assert Ok(Nil) = campy_peer.start_distribution("campy_peer_test_ide")
  gleeunit.main()
}

pub fn peer_boots_and_answers_round_trips_test() {
  let assert Ok(peer) = campy_peer.start("campy_peer_test")
  let assert Ok(node) = campy_peer.ping(peer)
  // The node name is `Name@Host` with the test's short name as its head.
  let assert True = starts_with(node, "campy_peer_test@")

  campy_peer.healthy([peer]) |> should.be_true

  campy_peer.stop(peer)
}

pub fn empty_name_is_rejected_test() {
  campy_peer.start("")
  |> should.equal(Error("campy_peer: node name must not be empty"))
}

pub fn call_runs_a_function_on_the_peer_test() {
  let assert Ok(peer) = campy_peer.start("campy_peer_call")

  // 2 + 3 evaluated on the peer node.
  let assert Ok(sum) =
    campy_peer.call(peer, "erlang", "+", [dynamic_int(2), dynamic_int(3)])

  int_of(sum) |> should.equal(5)

  campy_peer.stop(peer)
}

pub fn distribution_reports_the_test_node_test() {
  // The harness turned distribution on; this_node answers with it.
  let assert Ok(Nil) = campy_peer.start_distribution("campy_peer_test_ide")
  let assert True = starts_with(campy_peer.this_node(), "campy_peer_test_ide@")
}

@external(erlang, "campy_peer_test_ffi", "wrap_int")
fn dynamic_int(value: Int) -> anything

@external(erlang, "campy_peer_test_ffi", "read_int")
fn int_of(term: anything) -> Int

fn starts_with(haystack: String, needle: String) -> Bool {
  string.starts_with(haystack, needle)
}
