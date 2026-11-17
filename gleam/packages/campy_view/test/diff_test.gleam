import campy_view.{
  Insert, Order, Remove, Replace, SetEvents, SetProps, VInt, VText,
}
import campy_view/diff
import gleam/list
import gleeunit/should

fn label(id: String, text: String) -> campy_view.Node {
  campy_view.node("label", id)
  |> campy_view.with_props([#("text", VText(text))])
}

fn panel(id: String, children: List(campy_view.Node)) -> campy_view.Node {
  campy_view.node("panel", id) |> campy_view.with_children(children)
}

pub fn identical_trees_produce_no_patches_test() {
  diff.diff(panel("root", [label("a", "A")]), panel("root", [label("a", "A")]))
  |> should.equal([])
}

pub fn changed_prop_emits_full_prop_set_test() {
  diff.diff(label("a", "A"), label("a", "B"))
  |> should.equal([SetProps("a", [#("text", VText("B"))])])
}

pub fn added_prop_is_included_test() {
  let next =
    label("a", "A")
    |> campy_view.with_props([#("text", VText("A")), #("w", VInt(9))])

  diff.diff(label("a", "A"), next)
  |> should.equal([SetProps("a", [#("text", VText("A")), #("w", VInt(9))])])
}

pub fn removed_prop_is_absent_from_the_new_set_test() {
  let previous =
    label("a", "A")
    |> campy_view.with_props([#("text", VText("A")), #("w", VInt(9))])

  diff.diff(previous, label("a", "A"))
  |> should.equal([SetProps("a", [#("text", VText("A"))])])
}

pub fn changed_events_emit_event_set_test() {
  let previous = label("a", "A") |> campy_view.with_events(["click"])
  let next = label("a", "A") |> campy_view.with_events(["click", "focus"])

  diff.diff(previous, next)
  |> should.equal([SetEvents("a", ["click", "focus"])])
}

pub fn insert_at_end_uses_target_index_test() {
  diff.diff(
    panel("root", [label("a", "A")]),
    panel("root", [label("a", "A"), label("b", "B")]),
  )
  |> should.equal([Insert("root", 1, label("b", "B"))])
}

pub fn insert_in_middle_uses_target_index_test() {
  diff.diff(
    panel("root", [label("a", "A"), label("c", "C")]),
    panel("root", [label("a", "A"), label("b", "B"), label("c", "C")]),
  )
  |> should.equal([Insert("root", 1, label("b", "B"))])
}

pub fn multiple_inserts_use_target_indices_test() {
  diff.diff(
    panel("root", [label("a", "A")]),
    panel("root", [label("n", "N"), label("a", "A"), label("m", "M")]),
  )
  |> should.equal([
    Insert("root", 0, label("n", "N")),
    Insert("root", 2, label("m", "M")),
  ])
}

pub fn remove_child_emits_one_patch_test() {
  diff.diff(
    panel("root", [label("a", "A"), label("b", "B")]),
    panel("root", [label("a", "A")]),
  )
  |> should.equal([Remove("b")])
}

pub fn removing_a_subtree_emits_only_the_root_patch_test() {
  diff.diff(
    panel("root", [label("a", "A"), panel("b", [label("c", "C")])]),
    panel("root", [label("a", "A")]),
  )
  |> should.equal([Remove("b")])
}

pub fn reorder_emits_only_order_test() {
  diff.diff(
    panel("root", [label("a", "A"), label("b", "B"), label("c", "C")]),
    panel("root", [label("c", "C"), label("a", "A"), label("b", "B")]),
  )
  |> should.equal([Order("root", ["c", "a", "b"])])
}

pub fn insert_and_reorder_emits_order_last_test() {
  diff.diff(
    panel("root", [label("a", "A"), label("b", "B")]),
    panel("root", [label("b", "B"), label("n", "N"), label("a", "A")]),
  )
  |> should.equal([
    Insert("root", 1, label("n", "N")),
    Order("root", ["b", "n", "a"]),
  ])
}

pub fn nested_change_recurses_test() {
  diff.diff(panel("root", [label("a", "A")]), panel("root", [label("a", "B")]))
  |> should.equal([SetProps("a", [#("text", VText("B"))])])
}

pub fn kind_change_replaces_the_node_test() {
  let next =
    campy_view.node("button", "a")
    |> campy_view.with_props([#("text", VText("A"))])

  diff.diff(label("a", "A"), next) |> should.equal([Replace("a", next)])
}

pub fn identity_change_replaces_the_node_test() {
  let next = label("a", "A") |> campy_view.with_key("other")

  diff.diff(label("a", "A"), next) |> should.equal([Replace("a", next)])
}

pub fn keyed_row_with_new_id_is_replaced_then_ordered_test() {
  let previous =
    panel("root", [
      label("r1", "A") |> campy_view.with_key("row"),
      label("b", "B"),
    ])
  let next_row = label("r2", "A") |> campy_view.with_key("row")
  let next = panel("root", [next_row, label("b", "B")])

  diff.diff(previous, next)
  |> should.equal([Replace("r1", next_row), Order("root", ["r2", "b"])])
}

pub fn keyed_row_with_same_id_patches_in_place_test() {
  let previous = panel("root", [label("r1", "A") |> campy_view.with_key("row")])
  let next = panel("root", [label("r1", "B") |> campy_view.with_key("row")])

  diff.diff(previous, next)
  |> should.equal([SetProps("r1", [#("text", VText("B"))])])
}

pub fn props_compare_after_normalization_test() {
  let previous =
    label("a", "A")
    |> campy_view.with_props([#("w", VInt(1)), #("text", VText("A"))])
  let next =
    label("a", "A")
    |> campy_view.with_props([#("text", VText("A")), #("w", VInt(1))])

  diff.diff(previous, next) |> should.equal([])
}

pub fn reparent_hoists_remove_before_insert_test() {
  let previous =
    panel("root", [panel("left", []), panel("right", [label("b", "B")])])
  let next =
    panel("root", [panel("left", [label("b", "B")]), panel("right", [])])

  let patches = diff.diff(previous, next)

  patches
  |> list.first
  |> should.equal(Ok(Remove("b")))
}
