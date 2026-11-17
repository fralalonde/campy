import campy_design
import campy_ide_model
import campy_project
import campy_view.{VInt, VText}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn form(title: String) -> campy_view.Document {
  campy_view.Document(
    schema: 1,
    view: campy_view.node("form", "root")
      |> campy_view.with_props([#("title", VText(title))]),
    extra: [],
  )
}

fn module(slug: String, title: String) -> campy_project.Module {
  campy_project.Module(slug: slug, form: form(title), handlers: "")
}

fn project(title: String) -> campy_project.Project {
  campy_project.Project(
    title: title,
    modules: [module("a", "A"), module("b", "B")],
    extra: [],
  )
}

fn state() -> campy_ide_model.State {
  campy_ide_model.new(project("First"))
}

pub fn new_opens_the_first_module_test() {
  let state = state()
  state.open_tabs |> should.equal(["a"])
  state.active |> should.equal(Some("a"))
}

pub fn open_module_adds_a_tab_and_activates_test() {
  case campy_ide_model.open_module(state(), "b") {
    Ok(state) -> {
      state.open_tabs |> should.equal(["a", "b"])
      state.active |> should.equal(Some("b"))
    }
    Error(error) -> error |> should.equal("unexpected")
  }
}

pub fn open_module_refuses_unknown_slug_test() {
  campy_ide_model.open_module(state(), "nope")
  |> should.equal(Error("no such module: nope"))
}

pub fn open_module_twice_keeps_one_tab_test() {
  let assert Ok(state) = campy_ide_model.open_module(state(), "b")
  let assert Ok(state) = campy_ide_model.open_module(state, "b")
  state.open_tabs |> should.equal(["a", "b"])
}

pub fn close_active_module_picks_the_next_tab_test() {
  let assert Ok(state) = campy_ide_model.open_module(state(), "b")
  let state = campy_ide_model.close_module(state, "a")
  state.open_tabs |> should.equal(["b"])
  state.active |> should.equal(Some("b"))
}

pub fn close_last_tab_clears_active_test() {
  let state = campy_ide_model.close_module(state(), "a")
  state.open_tabs |> should.equal([])
  state.active |> should.equal(None)
}

pub fn selection_is_replaced_test() {
  let state = campy_ide_model.select_controls(state(), ["x", "y"])
  state.selection |> should.equal(["x", "y"])
}

pub fn commit_and_undo_restore_the_previous_project_test() {
  let state = state()
  let changed = project("Second")

  let state = campy_ide_model.commit(state, changed)
  state.undo |> list.length |> should.equal(1)

  let state = campy_ide_model.undo(state)
  state.project |> should.equal(project("First"))
  state.redo |> list.length |> should.equal(1)

  let state = campy_ide_model.redo(state)
  state.project |> should.equal(project("Second"))
}

pub fn identical_commit_is_not_recorded_test() {
  let state = state()
  campy_ide_model.commit(state, state.project).undo
  |> should.equal([])
}

pub fn new_commit_clears_redo_test() {
  let state =
    state()
    |> campy_ide_model.commit(project("Second"))
    |> campy_ide_model.undo

  state.redo |> list.length |> should.equal(1)

  let state = campy_ide_model.commit(state, project("Third"))
  state.redo |> should.equal([])
}

pub fn console_is_capped_and_newest_first_test() {
  let state =
    list.fold(from(1, 501), state(), fn(state, index) {
      campy_ide_model.log(state, int.to_string(index))
    })

  state.console |> list.length |> should.equal(campy_ide_model.console_limit)
  state.console |> list.first |> should.equal(Ok("501"))
}

pub fn console_text_is_chronological_test() {
  let state =
    state()
    |> campy_ide_model.log("a")
    |> campy_ide_model.log("b")

  campy_ide_model.console_text(state) |> should.equal("a\nb")
}

pub fn status_line_reports_module_selection_and_history_test() {
  let state =
    state()
    |> campy_ide_model.select_controls(["x"])
    |> campy_ide_model.commit(project("Second"))

  campy_ide_model.status_line(state)
  |> should.equal("a  sel:1  undo:1")
}

pub fn toggle_code_view_test() {
  let state = state()
  state.code_view |> should.be_false()
  campy_ide_model.toggle_code_view(state).code_view |> should.be_true()
}

pub fn active_module_returns_the_module_test() {
  case campy_ide_model.active_module(state()) {
    Ok(module) -> module.slug |> should.equal("a")
    Error(error) -> error |> should.equal("unexpected")
  }
}

pub fn update_dispatches_commands_test() {
  let state =
    campy_ide_model.update(state(), campy_ide_model.SetStatus("hello"))
    |> campy_ide_model.update(campy_ide_model.Log("line"))

  state.status |> should.equal("hello")
  state.console |> should.equal(["line"])

  let state = campy_ide_model.update(state, campy_ide_model.ToggleCodeView)
  state.code_view |> should.be_true()
}

fn from(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..from(start + 1, stop)]
  }
}

// --- T2.2: designer edits -------------------------------------------------

fn control(
  kind: String,
  id: String,
  props: List(#(String, campy_view.Value)),
) -> campy_view.Node {
  campy_view.node(kind, id) |> campy_view.with_props(props)
}

fn panel_node(id: String, x: Int, y: Int, w: Int, h: Int) -> campy_view.Node {
  control("panel", id, [
    #("x", VInt(x)),
    #("y", VInt(y)),
    #("w", VInt(w)),
    #("h", VInt(h)),
  ])
}

fn design_root(children: List(campy_view.Node)) -> campy_view.Node {
  control("form", "root", [
    #("w", VInt(600)),
    #("h", VInt(400)),
    #("layout", VText("free")),
  ])
  |> campy_view.with_children(children)
}

fn design_state(root: campy_view.Node) -> campy_ide_model.State {
  campy_ide_model.new(
    campy_project.Project(
      title: "Design",
      modules: [
        campy_project.Module(
          slug: "main",
          form: campy_view.Document(schema: 1, view: root, extra: []),
          handlers: "",
        ),
      ],
      extra: [],
    ),
  )
}

fn form_view(state: campy_ide_model.State) -> campy_view.Node {
  let assert Ok(module) = campy_ide_model.active_module(state)
  module.form.view
}

fn control_in(state: campy_ide_model.State, id: String) -> campy_view.Node {
  let assert Some(node) = campy_design.find_node(form_view(state), id)
  node
}

fn prop(
  state: campy_ide_model.State,
  id: String,
  name: String,
) -> Result(campy_view.Value, Nil) {
  campy_view.prop(control_in(state, id), name)
}

fn parent(state: campy_ide_model.State, id: String) -> Option(String) {
  campy_design.parent_of(form_view(state), id)
}

pub fn arm_and_disarm_test() {
  let state =
    design_state(design_root([]))
    |> campy_ide_model.update(campy_ide_model.Arm("button"))
  state.armed |> should.equal(Some("button"))
  state.status |> should.equal("Place Button: click or drag on the canvas")

  let state = campy_ide_model.update(state, campy_ide_model.Disarm)
  state.armed |> should.equal(None)
}

pub fn place_widget_adopts_the_deepest_container_test() {
  let root =
    design_root([
      campy_view.with_child(
        panel_node("panel", 100, 80, 300, 200),
        control("group", "group", [
          #("x", VInt(20)),
          #("y", VInt(20)),
          #("w", VInt(120)),
          #("h", VInt(100)),
        ]),
      ),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.Arm("button"))
    |> campy_ide_model.update(campy_ide_model.PlaceWidget(
      "button",
      140,
      110,
      0,
      0,
    ))

  state.armed |> should.equal(None)
  state.selection |> should.equal(["button_1"])
  parent(state, "button_1") |> should.equal(Some("group"))
  prop(state, "button_1", "x") |> should.equal(Ok(VInt(20)))
  prop(state, "button_1", "y") |> should.equal(Ok(VInt(10)))
  list.length(state.undo) |> should.equal(1)
}

pub fn place_widget_honors_drag_size_test() {
  let state =
    design_state(design_root([]))
    |> campy_ide_model.update(campy_ide_model.PlaceWidget(
      "text",
      30,
      40,
      120,
      44,
    ))

  prop(state, "text_1", "x") |> should.equal(Ok(VInt(30)))
  prop(state, "text_1", "y") |> should.equal(Ok(VInt(40)))
  prop(state, "text_1", "w") |> should.equal(Ok(VInt(120)))
  prop(state, "text_1", "h") |> should.equal(Ok(VInt(44)))
}

pub fn place_widget_freezes_a_column_form_test() {
  let root =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", VInt(600)),
      #("h", VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      control("label", "first", [#("text", VText("First")), #("h", VInt(20))]),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.PlaceWidget(
      "button",
      60,
      120,
      0,
      0,
    ))

  prop(state, "root", "layout") |> should.equal(Ok(VText("free")))
  prop(state, "button_1", "x") |> should.equal(Ok(VInt(60)))
  prop(state, "button_1", "y") |> should.equal(Ok(VInt(120)))
}

pub fn copy_paste_creates_fresh_ids_test() {
  let state =
    design_state(
      design_root([
        control("button", "ok", [
          #("x", VInt(10)),
          #("y", VInt(10)),
          #("w", VInt(80)),
          #("h", VInt(30)),
        ]),
      ]),
    )
    |> campy_ide_model.update(campy_ide_model.SelectControls(["ok"]))
    |> campy_ide_model.update(campy_ide_model.CopySelection)
    |> campy_ide_model.update(campy_ide_model.Paste)

  state.selection |> should.equal(["button_1"])
  parent(state, "button_1") |> should.equal(Some("root"))
  prop(state, "button_1", "x") |> should.equal(Ok(VInt(26)))
  campy_view.ids(form_view(state))
  |> should.equal(["root", "ok", "button_1"])
  list.length(state.undo) |> should.equal(1)
}

pub fn cut_then_paste_moves_the_subtree_test() {
  let state =
    design_state(
      design_root([
        control("button", "ok", [
          #("x", VInt(10)),
          #("y", VInt(10)),
          #("w", VInt(80)),
          #("h", VInt(30)),
        ]),
      ]),
    )
    |> campy_ide_model.update(campy_ide_model.SelectControls(["ok"]))
    |> campy_ide_model.update(campy_ide_model.CutSelection)

  campy_view.ids(form_view(state)) |> should.equal(["root"])
  state.selection |> should.equal([])

  let state = campy_ide_model.update(state, campy_ide_model.Paste)
  campy_view.ids(form_view(state)) |> should.equal(["root", "button_1"])
  state.selection |> should.equal(["button_1"])
}

pub fn paste_into_a_selected_container_test() {
  let state =
    design_state(
      design_root([
        control("button", "ok", [
          #("x", VInt(10)),
          #("y", VInt(10)),
          #("w", VInt(80)),
          #("h", VInt(30)),
        ]),
        panel_node("panel", 100, 50, 300, 200),
      ]),
    )
    |> campy_ide_model.update(campy_ide_model.SelectControls(["ok"]))
    |> campy_ide_model.update(campy_ide_model.CopySelection)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["panel"]))
    |> campy_ide_model.update(campy_ide_model.Paste)

  parent(state, "button_1") |> should.equal(Some("panel"))
}

pub fn duplicate_offsets_and_selects_the_copy_test() {
  let state =
    design_state(
      design_root([
        control("button", "ok", [
          #("x", VInt(10)),
          #("y", VInt(10)),
          #("w", VInt(80)),
          #("h", VInt(30)),
        ]),
      ]),
    )
    |> campy_ide_model.update(campy_ide_model.SelectControls(["ok"]))
    |> campy_ide_model.update(campy_ide_model.DuplicateSelection)

  state.selection |> should.equal(["button_1"])
  prop(state, "button_1", "x") |> should.equal(Ok(VInt(26)))
  prop(state, "button_1", "y") |> should.equal(Ok(VInt(26)))
  campy_view.ids(form_view(state))
  |> should.equal(["root", "ok", "button_1"])
}

pub fn duplicate_of_a_container_copies_its_children_test() {
  let root =
    design_root([
      panel_node("panel", 20, 20, 200, 120)
      |> campy_view.with_child(
        control("label", "inside", [
          #("x", VInt(5)),
          #("y", VInt(5)),
          #("w", VInt(40)),
          #("h", VInt(20)),
        ]),
      ),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(
      campy_ide_model.SelectControls(["inside", "panel"]),
    )
    |> campy_ide_model.update(campy_ide_model.DuplicateSelection)

  campy_view.ids(form_view(state))
  |> should.equal(["root", "panel", "inside", "panel_1", "label_1"])
  parent(state, "label_1") |> should.equal(Some("panel_1"))
}

pub fn delete_and_undo_restore_the_subtree_test() {
  let original =
    design_root([
      control("button", "ok", [
        #("x", VInt(10)),
        #("y", VInt(10)),
        #("w", VInt(80)),
        #("h", VInt(30)),
      ]),
    ])
  let state =
    design_state(original)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["ok"]))
    |> campy_ide_model.update(campy_ide_model.DeleteSelection)

  campy_view.ids(form_view(state)) |> should.equal(["root"])
  state.selection |> should.equal([])
  state.status |> should.equal("Deleted 1")

  let state = campy_ide_model.update(state, campy_ide_model.Undo)
  campy_view.ids(form_view(state)) |> should.equal(["root", "ok"])
}

pub fn z_order_commands_reorder_siblings_test() {
  let root =
    design_root([
      control("button", "a", [
        #("x", VInt(0)),
        #("y", VInt(0)),
        #("w", VInt(10)),
        #("h", VInt(10)),
      ]),
      control("button", "b", [
        #("x", VInt(0)),
        #("y", VInt(0)),
        #("w", VInt(10)),
        #("h", VInt(10)),
      ]),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["a"]))
    |> campy_ide_model.update(campy_ide_model.BringToFront)

  campy_view.ids(form_view(state)) |> should.equal(["root", "b", "a"])

  let state = campy_ide_model.update(state, campy_ide_model.SendToBack)
  campy_view.ids(form_view(state)) |> should.equal(["root", "a", "b"])
}

pub fn commit_geometry_reparents_and_keeps_absolute_position_test() {
  let root =
    design_root([
      control("button", "btn", [
        #("x", VInt(20)),
        #("y", VInt(20)),
        #("w", VInt(80)),
        #("h", VInt(30)),
      ]),
      panel_node("panel", 100, 80, 300, 200),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["btn"]))
    |> campy_ide_model.update(campy_ide_model.CommitGeometry(
      [#("btn", campy_design.Rect(150, 150, 90, 34))],
      Some(#("btn", "panel")),
    ))

  parent(state, "btn") |> should.equal(Some("panel"))
  prop(state, "btn", "x") |> should.equal(Ok(VInt(50)))
  prop(state, "btn", "y") |> should.equal(Ok(VInt(70)))
  campy_design.absolute(form_view(state), "btn")
  |> should.equal(Some(campy_design.Rect(150, 150, 90, 34)))

  let state = campy_ide_model.update(state, campy_ide_model.Undo)
  parent(state, "btn") |> should.equal(Some("root"))
  prop(state, "btn", "x") |> should.equal(Ok(VInt(20)))
}

pub fn commit_geometry_without_reparent_updates_the_rect_test() {
  let root =
    design_root([
      control("button", "btn", [
        #("x", VInt(20)),
        #("y", VInt(20)),
        #("w", VInt(80)),
        #("h", VInt(30)),
      ]),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.CommitGeometry(
      [#("btn", campy_design.Rect(60, 90, 100, 40))],
      None,
    ))

  prop(state, "btn", "x") |> should.equal(Ok(VInt(60)))
  prop(state, "btn", "y") |> should.equal(Ok(VInt(90)))
  prop(state, "btn", "w") |> should.equal(Ok(VInt(100)))
  prop(state, "btn", "h") |> should.equal(Ok(VInt(40)))
}

pub fn group_move_of_a_container_and_child_keeps_relative_geometry_test() {
  let root =
    design_root([
      panel_node("panel", 100, 50, 200, 100)
      |> campy_view.with_child(
        control("label", "inside", [
          #("x", VInt(20)),
          #("y", VInt(20)),
          #("w", VInt(40)),
          #("h", VInt(20)),
        ]),
      ),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(
      campy_ide_model.SelectControls(["panel", "inside"]),
    )
    |> campy_ide_model.update(campy_ide_model.CommitGeometry(
      [
        #("panel", campy_design.Rect(200, 150, 200, 100)),
        #("inside", campy_design.Rect(220, 170, 40, 20)),
      ],
      None,
    ))

  prop(state, "panel", "x") |> should.equal(Ok(VInt(200)))
  prop(state, "panel", "y") |> should.equal(Ok(VInt(150)))
  prop(state, "inside", "x") |> should.equal(Ok(VInt(20)))
  prop(state, "inside", "y") |> should.equal(Ok(VInt(20)))
  campy_design.absolute(form_view(state), "inside")
  |> should.equal(Some(campy_design.Rect(220, 170, 40, 20)))
}

pub fn paste_into_a_smaller_container_is_clamped_inside_test() {
  let root =
    design_root([
      control("button", "far", [
        #("x", VInt(300)),
        #("y", VInt(250)),
        #("w", VInt(100)),
        #("h", VInt(30)),
      ]),
      panel_node("panel", 100, 50, 240, 160),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["far"]))
    |> campy_ide_model.update(campy_ide_model.CopySelection)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["panel"]))
    |> campy_ide_model.update(campy_ide_model.Paste)

  parent(state, "button_1") |> should.equal(Some("panel"))
  prop(state, "button_1", "x") |> should.equal(Ok(VInt(140)))
  prop(state, "button_1", "y") |> should.equal(Ok(VInt(130)))
  campy_design.absolute(form_view(state), "button_1")
  |> should.equal(Some(campy_design.Rect(240, 180, 100, 30)))
}

pub fn copying_a_column_child_keeps_its_resolved_position_test() {
  let root =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", VInt(600)),
      #("h", VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      control("label", "a", [#("h", VInt(20)), #("text", VText("A"))]),
      control("label", "b", [#("h", VInt(20)), #("text", VText("B"))]),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["b"]))
    |> campy_ide_model.update(campy_ide_model.CopySelection)
    |> campy_ide_model.update(campy_ide_model.Paste)

  prop(state, "label_1", "x") |> should.equal(Ok(VInt(0)))
  prop(state, "label_1", "y") |> should.equal(Ok(VInt(40)))
  prop(state, "root", "layout") |> should.equal(Ok(VText("free")))
}

pub fn unchanged_geometry_does_not_freeze_or_commit_test() {
  let root =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", VInt(600)),
      #("h", VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      control("label", "a", [#("h", VInt(20)), #("text", VText("A"))]),
    ])

  let state = design_state(root)
  let layout = campy_design.resolve(form_view(state))
  let assert Some(placed) = campy_design.placed(layout, "a")

  let state =
    campy_ide_model.update(
      state,
      campy_ide_model.CommitGeometry([#("a", placed.rect)], None),
    )

  prop(state, "root", "layout") |> should.equal(Ok(VText("column")))
  list.length(state.undo) |> should.equal(0)
}

pub fn z_order_on_a_column_form_freezes_before_reordering_test() {
  let root =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", VInt(600)),
      #("h", VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      control("label", "a", [#("h", VInt(20)), #("text", VText("A"))]),
      control("label", "b", [#("h", VInt(20)), #("text", VText("B"))]),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SelectControls(["a"]))
    |> campy_ide_model.update(campy_ide_model.BringToFront)

  prop(state, "root", "layout") |> should.equal(Ok(VText("free")))
  campy_view.ids(form_view(state)) |> should.equal(["root", "b", "a"])
}

pub fn opening_a_module_clears_an_armed_kind_test() {
  let state =
    state()
    |> campy_ide_model.update(campy_ide_model.Arm("button"))
  state.armed |> should.equal(Some("button"))

  let assert Ok(state) = campy_ide_model.open_module(state, "b")
  state.armed |> should.equal(None)
}

// --- T2.3: inspector edits, events, and handler stubs ----------------------

fn text_button(id: String, text: String, x: Int, y: Int) -> campy_view.Node {
  control("button", id, [
    #("x", VInt(x)),
    #("y", VInt(y)),
    #("w", VInt(80)),
    #("h", VInt(30)),
    #("text", VText(text)),
  ])
  |> campy_view.with_events(["click"])
}

pub fn set_control_rect_clamps_size_and_records_one_undo_test() {
  let state =
    design_state(design_root([text_button("btn", "Go", 10, 10)]))
    |> campy_ide_model.update(campy_ide_model.SelectControls(["btn"]))
    |> campy_ide_model.update(campy_ide_model.SetControlRect(
      "btn",
      campy_design.Rect(40, 50, 2, 3),
    ))

  campy_design.absolute(form_view(state), "btn")
  |> should.equal(Some(campy_design.Rect(40, 50, campy_design.min_size, 8)))
  list.length(state.undo) |> should.equal(1)

  let state = campy_ide_model.update(state, campy_ide_model.Undo)
  campy_design.absolute(form_view(state), "btn")
  |> should.equal(Some(campy_design.Rect(10, 10, 80, 30)))
}

pub fn set_control_rect_uses_absolute_coordinates_in_a_nested_container_test() {
  let root =
    design_root([
      panel_node("panel", 100, 80, 300, 200)
      |> campy_view.with_child(text_button("btn", "Go", 20, 20)),
    ])

  let state =
    design_state(root)
    |> campy_ide_model.update(campy_ide_model.SetControlRect(
      "btn",
      campy_design.Rect(150, 120, 2, 2),
    ))

  prop(state, "btn", "x") |> should.equal(Ok(VInt(50)))
  prop(state, "btn", "y") |> should.equal(Ok(VInt(40)))
  campy_design.absolute(form_view(state), "btn")
  |> should.equal(Some(campy_design.Rect(150, 120, 8, 8)))
}

pub fn set_control_prop_text_records_one_undo_test() {
  let state =
    design_state(design_root([text_button("btn", "Go", 10, 10)]))
    |> campy_ide_model.update(campy_ide_model.SetControlProp(
      "btn",
      "text",
      VText("Hello"),
    ))

  prop(state, "btn", "text") |> should.equal(Ok(VText("Hello")))
  list.length(state.undo) |> should.equal(1)

  let state = campy_ide_model.update(state, campy_ide_model.Undo)
  prop(state, "btn", "text") |> should.equal(Ok(VText("Go")))
  list.length(state.undo) |> should.equal(0)
}

pub fn set_control_prop_to_the_same_value_is_not_undone_test() {
  let state =
    design_state(design_root([text_button("btn", "Go", 10, 10)]))
    |> campy_ide_model.update(campy_ide_model.SetControlProp(
      "btn",
      "text",
      VText("Go"),
    ))

  state.undo |> should.equal([])
}

pub fn set_handlers_records_undo_test() {
  let state =
    design_state(design_root([]))
    |> campy_ide_model.update(campy_ide_model.SetHandlers(
      "pub fn init() {\n  Nil\n}\n",
    ))

  let assert Ok(module) = campy_ide_model.active_module(state)
  module.handlers |> should.equal("pub fn init() {\n  Nil\n}\n")
  list.length(state.undo) |> should.equal(1)

  let state = campy_ide_model.update(state, campy_ide_model.Undo)
  let assert Ok(module) = campy_ide_model.active_module(state)
  module.handlers |> should.equal("")
}

pub fn handler_name_and_existence_use_the_abi_v2_shape_test() {
  campy_ide_model.handler_name("save_button", "click")
  |> should.equal("save_button_click")

  campy_ide_model.handler_exists(
    "pub fn save_button_click(state: State, event: Event) -> #(State, List(Effect)) {\n",
    "save_button_click",
  )
  |> should.be_true()

  campy_ide_model.handler_exists("pub fn other(", "save_button_click")
  |> should.be_false()
}

pub fn handler_stub_is_an_abi_v2_function_test() {
  campy_ide_model.handler_stub("ok_click")
  |> should.equal(
    "pub fn ok_click(state: State, event: Event) -> #(State, List(Effect)) {\n"
    <> "  let _ = event\n"
    <> "  #(state, [])\n"
    <> "}\n",
  )
}

pub fn open_handler_appends_one_stub_and_shows_code_test() {
  let state =
    design_state(design_root([text_button("btn", "Go", 10, 10)]))
    |> campy_ide_model.update(campy_ide_model.OpenHandler("btn", "click"))

  state.code_view |> should.be_true()
  let assert Ok(module) = campy_ide_model.active_module(state)
  string.contains(module.handlers, "pub fn btn_click(")
  |> should.be_true()
  list.length(string.split(module.handlers, "pub fn btn_click("))
  |> should.equal(2)
  list.length(state.undo) |> should.equal(1)
  state.status |> should.equal("Added handler btn_click")

  let state =
    campy_ide_model.update(state, campy_ide_model.OpenHandler("btn", "click"))
  let assert Ok(module) = campy_ide_model.active_module(state)
  list.length(string.split(module.handlers, "pub fn btn_click("))
  |> should.equal(2)
  list.length(state.undo) |> should.equal(1)
  state.status |> should.equal("Opened btn_click")
}

pub fn open_handler_keeps_existing_handlers_verbatim_test() {
  let state =
    design_state(design_root([text_button("btn", "Go", 10, 10)]))
    |> campy_ide_model.update(campy_ide_model.SetHandlers(
      "pub fn btn_click(state: State, event: Event) -> #(State, List(Effect)) {\n"
      <> "  #(state, [])\n"
      <> "}\n",
    ))

  let handlers_before = case campy_ide_model.active_module(state) {
    Ok(module) -> module.handlers
    Error(_) -> ""
  }

  let state =
    campy_ide_model.update(state, campy_ide_model.OpenHandler("btn", "click"))
  let assert Ok(module) = campy_ide_model.active_module(state)
  module.handlers |> should.equal(handlers_before)
  list.length(state.undo) |> should.equal(1)
}

pub fn selected_events_follow_the_single_selection_test() {
  let state =
    design_state(
      design_root([
        text_button("btn", "Go", 10, 10),
        text_button("other", "Stop", 120, 10),
      ]),
    )

  campy_ide_model.selected_events(state) |> should.equal([])

  let state = campy_ide_model.select_controls(state, ["btn"])
  campy_ide_model.selected_events(state) |> should.equal(["click"])

  let state = campy_ide_model.select_controls(state, ["btn", "other"])
  campy_ide_model.selected_events(state) |> should.equal([])
}
