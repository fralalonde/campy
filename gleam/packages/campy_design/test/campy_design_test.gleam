import campy_design
import campy_view.{VInt, VText}
import gleam/list
import gleam/option.{type Option, None, Some}
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

fn box(id: String, x: Int, y: Int, w: Int, h: Int) -> campy_view.Node {
  node("label", id, [
    #("h", VInt(h)),
    #("w", VInt(w)),
    #("x", VInt(x)),
    #("y", VInt(y)),
  ])
}

fn form(
  props: List(#(String, campy_view.Value)),
  children: List(campy_view.Node),
) -> campy_view.Node {
  node("form", "root", [#("h", VInt(400)), #("w", VInt(600)), ..props])
  |> campy_view.with_children(children)
}

fn find(node: campy_view.Node, id: String) -> Option(campy_view.Node) {
  case node.id == id {
    True -> Some(node)
    False -> first_some(list.map(node.children, fn(child) { find(child, id) }))
  }
}

fn first_some(items: List(Option(a))) -> Option(a) {
  case items {
    [] -> None
    [Some(value), ..] -> Some(value)
    [None, ..rest] -> first_some(rest)
  }
}

fn prop_of(
  tree: campy_view.Node,
  id: String,
  name: String,
) -> Result(campy_view.Value, Nil) {
  let assert Some(node) = find(tree, id)
  campy_view.prop(node, name)
}

fn rect_of(layout: campy_design.Layout, id: String) -> campy_design.Rect {
  let assert Ok(found) =
    list.find(layout.places, fn(placed) { placed.id == id })
  found.rect
}

pub fn free_children_are_parent_relative_test() {
  let layout = campy_design.resolve(form([], [box("a", 16, 24, 80, 20)]))

  rect_of(layout, "a") |> should.equal(campy_design.Rect(16, 24, 80, 20))
}

pub fn missing_geometry_uses_kind_defaults_test() {
  let layout = campy_design.resolve(form([], [campy_view.node("label", "a")]))

  rect_of(layout, "a")
  |> should.equal(campy_design.Rect(
    0,
    0,
    campy_design.default_w("label"),
    campy_design.default_h("label"),
  ))
}

pub fn border_insets_children_test() {
  let layout =
    campy_design.resolve(form([#("border", VInt(8))], [box("a", 0, 0, 50, 20)]))

  rect_of(layout, "a") |> should.equal(campy_design.Rect(8, 8, 50, 20))
}

pub fn nested_containers_accumulate_offsets_test() {
  let panel =
    node("panel", "panel", [
      #("h", VInt(200)),
      #("w", VInt(300)),
      #("x", VInt(20)),
      #("y", VInt(30)),
    ])
    |> campy_view.with_children([box("a", 5, 6, 40, 18)])

  let layout = campy_design.resolve(form([], [panel]))

  rect_of(layout, "panel") |> should.equal(campy_design.Rect(20, 30, 300, 200))
  rect_of(layout, "a") |> should.equal(campy_design.Rect(25, 36, 40, 18))
}

pub fn column_stacks_children_with_gap_test() {
  let layout =
    campy_design.resolve(
      form(
        [#("border", VInt(8)), #("gap", VInt(4)), #("layout", VText("column"))],
        [
          box("a", 0, 0, 10, 20),
          node("label", "b", [#("h", VInt(30))]),
        ],
      ),
    )

  rect_of(layout, "a") |> should.equal(campy_design.Rect(8, 8, 584, 20))
  rect_of(layout, "b") |> should.equal(campy_design.Rect(8, 32, 584, 30))
}

pub fn row_stacks_children_with_gap_test() {
  let layout =
    campy_design.resolve(
      form(
        [#("border", VInt(8)), #("gap", VInt(4)), #("layout", VText("row"))],
        [box("a", 0, 0, 100, 10), box("b", 0, 0, 50, 10)],
      ),
    )

  rect_of(layout, "a") |> should.equal(campy_design.Rect(8, 8, 100, 384))
  rect_of(layout, "b") |> should.equal(campy_design.Rect(112, 8, 50, 384))
}

pub fn alignment_overrides_free_geometry_test() {
  let layout =
    campy_design.resolve(
      form([#("border", VInt(8))], [
        node("label", "client", [#("align", VText("client"))]),
        node("label", "top", [
          #("align", VText("top")),
          #("h", VInt(20)),
          #("w", VInt(50)),
        ]),
        node("label", "right", [
          #("align", VText("right")),
          #("w", VInt(60)),
        ]),
      ]),
    )

  rect_of(layout, "client") |> should.equal(campy_design.Rect(8, 8, 584, 384))
  rect_of(layout, "top") |> should.equal(campy_design.Rect(8, 8, 584, 20))
  rect_of(layout, "right") |> should.equal(campy_design.Rect(532, 8, 60, 384))
}

pub fn hit_test_picks_the_last_painted_control_test() {
  let layout =
    campy_design.resolve(
      form([], [box("a", 0, 0, 100, 100), box("b", 50, 50, 100, 100)]),
    )

  case campy_design.at(layout, 60, 60) {
    Some(placed) -> placed.id |> should.equal("b")
    None -> should.fail()
  }

  case campy_design.at(layout, 200, 300) {
    Some(placed) -> placed.id |> should.equal("root")
    None -> should.fail()
  }
}

pub fn container_hit_test_finds_the_deepest_container_test() {
  let panel =
    node("panel", "panel", [
      #("h", VInt(100)),
      #("w", VInt(200)),
      #("x", VInt(10)),
      #("y", VInt(10)),
    ])
    |> campy_view.with_children([box("a", 5, 5, 40, 20)])

  let layout = campy_design.resolve(form([], [panel]))

  case campy_design.container_at(layout, 20, 20) {
    Some(placed) -> placed.id |> should.equal("panel")
    None -> should.fail()
  }

  case campy_design.container_at(layout, 500, 300) {
    Some(placed) -> placed.id |> should.equal("root")
    None -> should.fail()
  }
}

pub fn move_updates_position_and_clears_alignment_test() {
  let moved =
    campy_design.move(
      form([], [node("label", "a", [#("align", VText("top"))])]),
      "a",
      10,
      -4,
    )

  prop_of(moved, "a", "x") |> should.equal(Ok(VInt(10)))
  prop_of(moved, "a", "y") |> should.equal(Ok(VInt(-4)))
  prop_of(moved, "a", "align") |> should.equal(Ok(VText("none")))
}

pub fn resize_clamps_to_minimum_test() {
  let resized =
    campy_design.resize(form([], [box("a", 0, 0, 10, 10)]), "a", -50, -50)

  prop_of(resized, "a", "w")
  |> should.equal(Ok(VInt(campy_design.min_size)))
  prop_of(resized, "a", "h")
  |> should.equal(Ok(VInt(campy_design.min_size)))
}

pub fn set_rect_writes_all_geometry_test() {
  let placed =
    campy_design.set_rect(
      form([], [node("label", "a", [])]),
      "a",
      campy_design.Rect(5, 6, 70, 40),
    )

  prop_of(placed, "a", "x") |> should.equal(Ok(VInt(5)))
  prop_of(placed, "a", "y") |> should.equal(Ok(VInt(6)))
  prop_of(placed, "a", "w") |> should.equal(Ok(VInt(70)))
  prop_of(placed, "a", "h") |> should.equal(Ok(VInt(40)))
}

pub fn unknown_ids_are_ignored_test() {
  let tree = form([], [box("a", 0, 0, 10, 10)])
  campy_design.move(tree, "nope", 5, 5) |> should.equal(tree)
}

pub fn containers_are_classified_test() {
  campy_design.is_container("form") |> should.be_true()
  campy_design.is_container("panel") |> should.be_true()
  campy_design.is_container("label") |> should.be_false()
}
