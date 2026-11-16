import campy_view.{VInt, VText}
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn label(id: String, text: String) -> campy_view.Node {
  campy_view.node("label", id)
  |> campy_view.with_props([#("text", VText(text))])
}

pub fn identity_uses_id_without_key_test() {
  label("a", "A")
  |> campy_view.identity
  |> should.equal("a")
}

pub fn identity_prefers_key_test() {
  label("a", "A")
  |> campy_view.with_key("row-7")
  |> campy_view.identity
  |> should.equal("row-7")
}

pub fn normalize_sorts_props_test() {
  campy_view.node("label", "a")
  |> campy_view.with_props([#("z", VInt(1)), #("a", VText("x"))])
  |> campy_view.normalize
  |> fn(node) { node.props }
  |> should.equal([#("a", VText("x")), #("z", VInt(1))])
}

pub fn normalize_keeps_last_duplicate_prop_test() {
  campy_view.node("label", "a")
  |> campy_view.with_props([#("text", VText("first")), #("text", VText("last"))])
  |> campy_view.normalize
  |> fn(node) { node.props }
  |> should.equal([#("text", VText("last"))])
}

pub fn normalize_dedupes_events_in_first_seen_order_test() {
  campy_view.node("button", "a")
  |> campy_view.with_events(["click", "focus", "click"])
  |> campy_view.normalize
  |> fn(node) { node.events }
  |> should.equal(["click", "focus"])
}

pub fn normalize_recurses_into_children_test() {
  let child =
    campy_view.node("label", "b")
    |> campy_view.with_props([#("z", VInt(1)), #("a", VInt(2))])

  campy_view.node("panel", "a")
  |> campy_view.with_children([child])
  |> campy_view.normalize
  |> fn(node) { node.children }
  |> should.equal([
    campy_view.node("label", "b")
    |> campy_view.with_props([#("a", VInt(2)), #("z", VInt(1))]),
  ])
}

pub fn prop_reads_by_name_test() {
  label("a", "Cats")
  |> campy_view.prop("text")
  |> should.equal(Ok(VText("Cats")))
}

pub fn prop_missing_is_error_test() {
  label("a", "Cats")
  |> campy_view.prop("w")
  |> should.equal(Error(Nil))
}

pub fn with_key_keeps_other_fields_test() {
  let built =
    label("a", "Cats")
    |> campy_view.with_key("row-1")

  built.id |> should.equal("a")
  built.key |> should.equal(Some("row-1"))
  built.props |> should.equal([#("text", VText("Cats"))])
}

pub fn validate_accepts_a_tree_test() {
  let tree =
    campy_view.node("panel", "root")
    |> campy_view.with_child(label("a", "A"))
    |> campy_view.with_child(
      campy_view.node("panel", "b") |> campy_view.with_child(label("c", "C")),
    )

  campy_view.validate(tree) |> should.equal(Ok(Nil))
}

pub fn validate_rejects_duplicate_id_test() {
  let tree =
    campy_view.node("panel", "root")
    |> campy_view.with_child(label("dup", "A"))
    |> campy_view.with_child(label("dup", "B"))

  campy_view.validate(tree)
  |> should.equal(Error("duplicate sibling key or id: dup"))
}

pub fn validate_rejects_duplicate_id_across_parents_test() {
  let tree =
    campy_view.node("panel", "root")
    |> campy_view.with_child(
      campy_view.node("panel", "p1") |> campy_view.with_child(label("dup", "A")),
    )
    |> campy_view.with_child(
      campy_view.node("panel", "p2") |> campy_view.with_child(label("dup", "B")),
    )

  campy_view.validate(tree) |> should.equal(Error("duplicate node id: dup"))
}

pub fn validate_rejects_duplicate_sibling_key_test() {
  let tree =
    campy_view.node("panel", "root")
    |> campy_view.with_child(label("a", "A") |> campy_view.with_key("row"))
    |> campy_view.with_child(label("b", "B") |> campy_view.with_key("row"))

  campy_view.validate(tree)
  |> should.equal(Error("duplicate sibling key or id: row"))
}

pub fn validate_rejects_empty_id_test() {
  campy_view.node("label", "")
  |> campy_view.validate
  |> should.equal(Error("node id must not be empty"))
}

pub fn validate_rejects_empty_key_test() {
  label("a", "A")
  |> campy_view.with_key("")
  |> campy_view.validate
  |> should.equal(Error("node key must not be empty: a"))
}

pub fn ids_are_preorder_test() {
  let tree =
    campy_view.node("panel", "root")
    |> campy_view.with_child(
      campy_view.node("panel", "b") |> campy_view.with_child(label("c", "C")),
    )
    |> campy_view.with_child(label("d", "D"))

  campy_view.ids(tree) |> should.equal(["root", "b", "c", "d"])
}

pub fn key_none_by_default_test() {
  label("a", "A").key |> should.equal(None)
}
