import campy_view.{
  type Node, type Patch, Insert, Order, Remove, Replace, SetEvents, SetProps,
  VInt, VText,
}
import campy_view/diff
import gleam/list
import gleeunit/should

// Reference applier: proves that a patch batch reconstructs the target tree.
// The wx renderer has the same semantics against live widgets.

fn label(id: String, text: String) -> Node {
  campy_view.node("label", id)
  |> campy_view.with_props([#("text", VText(text))])
}

fn panel(id: String, children: List(Node)) -> Node {
  campy_view.node("panel", id) |> campy_view.with_children(children)
}

fn apply_patches(root: Node, patches: List(Patch)) -> Node {
  list.fold(patches, root, apply_patch)
}

fn apply_patch(root: Node, patch: Patch) -> Node {
  case patch {
    SetProps(id, props) ->
      update_node(root, id, fn(node) { campy_view.with_props(node, props) })
    SetEvents(id, events) ->
      update_node(root, id, fn(node) { campy_view.with_events(node, events) })
    Insert(parent, index, child) ->
      update_node(root, parent, fn(node) {
        campy_view.with_children(node, insert_at(node.children, index, child))
      })
    Remove(id) -> remove_node(root, id)
    Order(parent, ids) ->
      update_node(root, parent, fn(node) {
        campy_view.with_children(node, reorder(node.children, ids))
      })
    Replace(id, node) -> update_node(root, id, fn(_) { node })
  }
}

fn update_node(node: Node, id: String, change: fn(Node) -> Node) -> Node {
  case node.id == id {
    True -> change(node)
    False ->
      campy_view.with_children(
        node,
        list.map(node.children, fn(child) { update_node(child, id, change) }),
      )
  }
}

fn remove_node(node: Node, id: String) -> Node {
  campy_view.with_children(
    node,
    node.children
      |> list.filter(fn(child) { child.id != id })
      |> list.map(fn(child) { remove_node(child, id) }),
  )
}

fn insert_at(items: List(a), index: Int, item: a) -> List(a) {
  let #(before, after) = list.split(items, index)
  list.append(before, list.append([item], after))
}

fn reorder(children: List(Node), ids: List(String)) -> List(Node) {
  ids
  |> list.filter_map(fn(id) {
    list.find(children, fn(child) { child.id == id })
  })
}

fn assert_reconstructs(previous: Node, next: Node) {
  apply_patches(previous, diff.diff(previous, next))
  |> campy_view.normalize
  |> should.equal(campy_view.normalize(next))
}

pub fn identical_reconstructs_test() {
  assert_reconstructs(
    panel("root", [label("a", "A")]),
    panel("root", [label("a", "A")]),
  )
}

pub fn prop_change_reconstructs_test() {
  assert_reconstructs(label("a", "A"), label("a", "B"))
}

pub fn added_and_removed_props_reconstruct_test() {
  let previous =
    label("a", "A")
    |> campy_view.with_props([#("text", VText("A")), #("w", VInt(9))])
  let next =
    label("a", "A")
    |> campy_view.with_props([#("text", VText("A")), #("h", VInt(4))])

  assert_reconstructs(previous, next)
}

pub fn insert_in_middle_reconstructs_test() {
  assert_reconstructs(
    panel("root", [label("a", "A"), label("c", "C")]),
    panel("root", [label("a", "A"), label("b", "B"), label("c", "C")]),
  )
}

pub fn multiple_inserts_reconstruct_test() {
  assert_reconstructs(
    panel("root", [label("a", "A")]),
    panel("root", [label("n", "N"), label("a", "A"), label("m", "M")]),
  )
}

pub fn remove_subtree_reconstructs_test() {
  assert_reconstructs(
    panel("root", [label("a", "A"), panel("b", [label("c", "C")])]),
    panel("root", [label("a", "A")]),
  )
}

pub fn reorder_reconstructs_test() {
  assert_reconstructs(
    panel("root", [label("a", "A"), label("b", "B"), label("c", "C")]),
    panel("root", [label("c", "C"), label("a", "A"), label("b", "B")]),
  )
}

pub fn insert_and_reorder_reconstructs_test() {
  assert_reconstructs(
    panel("root", [label("a", "A"), label("b", "B")]),
    panel("root", [label("b", "B"), label("n", "N"), label("a", "A")]),
  )
}

pub fn nested_change_reconstructs_test() {
  assert_reconstructs(
    panel("root", [panel("inner", [label("a", "A")]), label("b", "B")]),
    panel("root", [
      panel("inner", [label("a", "A2"), label("c", "C")]),
      label("b", "B"),
    ]),
  )
}

pub fn kind_change_reconstructs_test() {
  let next =
    campy_view.node("button", "a")
    |> campy_view.with_props([#("text", VText("A"))])

  assert_reconstructs(label("a", "A"), next)
}

pub fn keyed_row_with_new_id_reconstructs_test() {
  let previous =
    panel("root", [
      label("r1", "A") |> campy_view.with_key("row"),
      label("b", "B"),
    ])
  let next =
    panel("root", [
      label("r2", "A") |> campy_view.with_key("row"),
      label("b", "B"),
    ])

  assert_reconstructs(previous, next)
}

pub fn changed_key_on_same_id_reconstructs_test() {
  let previous = panel("root", [label("a", "A") |> campy_view.with_key("k1")])
  let next = panel("root", [label("a", "A") |> campy_view.with_key("k2")])

  assert_reconstructs(previous, next)
}

pub fn root_identity_change_reconstructs_test() {
  assert_reconstructs(
    label("a", "A"),
    label("a", "A") |> campy_view.with_key("root"),
  )
}

pub fn combined_edit_reconstructs_test() {
  let previous =
    panel("root", [
      label("a", "A"),
      label("b", "B") |> campy_view.with_key("row-1"),
      panel("box", [label("c", "C"), label("d", "D")]),
      label("e", "E"),
    ])
  let next =
    panel("root", [
      label("n", "N"),
      label("b", "B2") |> campy_view.with_key("row-1"),
      panel("box", [label("d", "D"), label("f", "F")]),
      label("a", "A"),
    ])

  assert_reconstructs(previous, next)
}
