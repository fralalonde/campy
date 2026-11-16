import campy_view.{VBool, VInt, VList, VText}
import campy_wx/plan
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn node(
  kind: String,
  id: String,
  props: List(#(String, campy_view.Value)),
) -> campy_view.Node {
  campy_view.node(kind, id) |> campy_view.with_props(props)
}

pub fn layout_defaults_to_free_test() {
  node("panel", "a", []) |> plan.layout |> should.equal(plan.Free)
}

pub fn layout_reads_column_and_row_test() {
  node("panel", "a", [#("layout", VText("column"))])
  |> plan.layout
  |> should.equal(plan.Column)

  node("panel", "a", [#("layout", VText("row"))])
  |> plan.layout
  |> should.equal(plan.Row)
}

pub fn unknown_layout_is_free_test() {
  node("panel", "a", [#("layout", VText("diagonal"))])
  |> plan.layout
  |> should.equal(plan.Free)
}

pub fn border_defaults_to_zero_test() {
  node("panel", "a", []) |> plan.border |> should.equal(0)
}

pub fn border_reads_int_test() {
  node("panel", "a", [#("border", VInt(6))]) |> plan.border |> should.equal(6)
}

pub fn changed_props_reports_added_and_changed_test() {
  plan.changed_props([#("a", VInt(1))], [#("a", VInt(2)), #("b", VText("x"))])
  |> should.equal([#("a", VInt(2)), #("b", VText("x"))])
}

pub fn changed_props_ignores_equal_values_test() {
  plan.changed_props([#("a", VInt(1)), #("b", VText("x"))], [
    #("b", VText("x")),
    #("a", VInt(1)),
  ])
  |> should.equal([])
}

pub fn changed_props_ignores_removed_values_test() {
  plan.changed_props([#("a", VInt(1)), #("b", VInt(2))], [#("a", VInt(3))])
  |> should.equal([#("a", VInt(3))])
}

pub fn event_keys_map_by_kind_test() {
  plan.event_key("button") |> should.equal("click")
  plan.event_key("checkbox") |> should.equal("click")
  plan.event_key("text") |> should.equal("change")
  plan.event_key("slider") |> should.equal("change")
  plan.event_key("window") |> should.equal("close")
}

pub fn chrome_event_keys_map_test() {
  plan.event_key("menuitem") |> should.equal("click")
  plan.event_key("tool") |> should.equal("click")
  plan.event_key("tree") |> should.equal("select")
  plan.event_key("notebook") |> should.equal("change")
  plan.event_key("grid") |> should.equal("change")
}

pub fn prop_readers_are_typed_test() {
  let props = [#("text", VText("hi")), #("n", VInt(3)), #("on", VBool(True))]

  plan.text_of(props, "text") |> should.equal(Ok("hi"))
  plan.int_of(props, "n") |> should.equal(Ok(3))
  plan.bool_of(props, "on") |> should.equal(Ok(True))
  plan.text_of(props, "n") |> should.equal(Error(Nil))
}

pub fn items_reader_extracts_strings_test() {
  plan.items_of([#("items", VList([VText("a"), VText("b")]))], "items")
  |> should.equal(["a", "b"])
}

pub fn items_reader_skips_non_strings_test() {
  plan.items_of([#("items", VList([VText("a"), VInt(2)]))], "items")
  |> should.equal(["a"])
}

pub fn containers_are_identified_test() {
  plan.is_container("panel") |> should.be_true()
  plan.is_container("group") |> should.be_true()
  plan.is_container("window") |> should.be_true()
  plan.is_container("page") |> should.be_true()
  plan.is_container("label") |> should.be_false()
}
