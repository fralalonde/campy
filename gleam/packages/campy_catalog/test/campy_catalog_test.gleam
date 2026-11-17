import campy_catalog
import campy_view.{VBool, VInt, VList, VText}
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn catalog_kinds_are_unique_test() {
  let kinds = list.map(campy_catalog.all(), fn(widget) { widget.kind })
  list.unique(kinds) |> should.equal(kinds)
}

pub fn every_catalog_kind_is_findable_test() {
  campy_catalog.all()
  |> list.each(fn(widget) {
    campy_catalog.find(widget.kind) |> should.equal(Ok(widget))
  })
}

pub fn unknown_kind_is_refused_test() {
  campy_catalog.find("nope")
  |> should.equal(Error("unknown widget kind: nope"))
}

pub fn containers_are_declared_test() {
  campy_catalog.accepts_children("panel") |> should.equal(True)
  campy_catalog.accepts_children("group") |> should.equal(True)
  campy_catalog.accepts_children("form") |> should.equal(True)
  campy_catalog.accepts_children("button") |> should.equal(False)
}

pub fn make_uses_defaults_and_events_test() {
  let assert Ok(node) = campy_catalog.make("button", "ok")
  node.kind |> should.equal("button")
  node.id |> should.equal("ok")
  node.events |> should.equal(["click"])
  campy_view.prop(node, "text") |> should.equal(Ok(VText("Button")))
  campy_view.prop(node, "w")
  |> should.equal(Ok(VInt(campy_catalog.default_w("button"))))
  campy_view.prop(node, "h")
  |> should.equal(Ok(VInt(campy_catalog.default_h("button"))))
}

pub fn make_at_sets_exact_geometry_test() {
  let assert Ok(node) = campy_catalog.make_at("text", "name", 12, 20, 180, 32)
  campy_view.prop(node, "x") |> should.equal(Ok(VInt(12)))
  campy_view.prop(node, "y") |> should.equal(Ok(VInt(20)))
  campy_view.prop(node, "w") |> should.equal(Ok(VInt(180)))
  campy_view.prop(node, "h") |> should.equal(Ok(VInt(32)))
}

pub fn make_at_clamps_negative_geometry_test() {
  let assert Ok(node) = campy_catalog.make_at("text", "name", -5, -7, 0, -3)
  campy_view.prop(node, "x") |> should.equal(Ok(VInt(0)))
  campy_view.prop(node, "y") |> should.equal(Ok(VInt(0)))
  campy_view.prop(node, "w") |> should.equal(Ok(VInt(1)))
  campy_view.prop(node, "h") |> should.equal(Ok(VInt(1)))
}

pub fn input_defaults_are_typed_test() {
  let assert Ok(checkbox) = campy_catalog.make("checkbox", "ok")
  campy_view.prop(checkbox, "value") |> should.equal(Ok(VBool(False)))

  let assert Ok(choice) = campy_catalog.make("choice", "pick")
  campy_view.prop(choice, "items")
  |> should.equal(Ok(VList([VText("One"), VText("Two")])))
}

pub fn unknown_kind_has_no_events_test() {
  campy_catalog.events("nope") |> should.equal([])
  campy_catalog.label_of("nope") |> should.equal("nope")
}
