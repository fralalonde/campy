import campy_ide_model as model
import campy_ide_wx
import campy_project
import campy_view.{VInt, VText}
import campy_wx/plan.{TreeItem}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn module(slug: String) -> campy_project.Module {
  campy_project.Module(
    slug: slug,
    form: campy_view.Document(
      schema: 1,
      view: campy_view.node("form", "root"),
      extra: [],
    ),
    handlers: "",
  )
}

fn project() -> campy_project.Project {
  campy_project.Project(
    title: "Demo",
    modules: [module("greeter"), module("notes")],
    extra: [],
  )
}

pub fn tree_has_a_project_root_with_modules_test() {
  let items = campy_ide_wx.tree_items(model.new(project()))

  let assert [TreeItem(key, label, children)] = items
  key |> should.equal("project")
  label |> should.equal("Demo")
  children |> list.length |> should.equal(2)
}

pub fn inspector_reports_the_active_module_test() {
  let rows = campy_ide_wx.inspector_rows(model.new(project()))

  rows
  |> should.equal([
    ["Field", "Value", "Field", "Value"],
    ["Project", "Demo", "Module", "greeter"],
    ["Tabs", "1", "History", "0"],
  ])
}

pub fn status_and_console_start_empty_test() {
  let state = model.new(project())
  state.console |> should.equal([])
  state.status |> should.equal("")
}

pub fn handlers_are_text_test() {
  let state = model.new(project())
  let assert Ok(active) = model.active_module(state)
  active.handlers |> should.equal("")
  active.slug |> should.equal("greeter")
}

pub fn document_title_is_available_test() {
  let assert Ok(active) = model.active_module(model.new(project()))
  campy_view.prop(active.form.view, "title") |> should.equal(Error(Nil))

  let labelled =
    campy_project.Module(
      slug: "x",
      form: campy_view.Document(
        schema: 1,
        view: campy_view.node("form", "root")
          |> campy_view.with_props([#("title", VText("X"))]),
        extra: [],
      ),
      handlers: "",
    )

  campy_view.prop(labelled.form.view, "title")
  |> should.equal(Ok(VText("X")))
}

pub fn palette_lists_every_catalog_widget_test() {
  let labels = campy_ide_wx.palette_labels()
  labels |> list.length |> should.equal(16)
  labels |> list.first |> should.equal(Ok("Panel"))
  labels |> list.contains("Panel") |> should.equal(True)
}

pub fn inspector_shows_the_parent_of_a_control_test() {
  let view =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", campy_view.VInt(400)),
      #("h", campy_view.VInt(300)),
    ])
    |> campy_view.with_child(
      campy_view.node("button", "ok")
      |> campy_view.with_props([
        #("x", campy_view.VInt(10)),
        #("y", campy_view.VInt(12)),
        #("w", campy_view.VInt(80)),
        #("h", campy_view.VInt(30)),
      ]),
    )

  let state =
    model.new(
      campy_project.Project(
        title: "Demo",
        modules: [
          campy_project.Module(
            slug: "main",
            form: campy_view.Document(schema: 1, view: view, extra: []),
            handlers: "",
          ),
        ],
        extra: [],
      ),
    )
    |> model.select_controls(["ok"])

  campy_ide_wx.inspector_rows(state)
  |> should.equal([
    ["Field", "Value", "Field", "Value"],
    ["id", "ok", "kind", "button"],
    ["parent", "root", "x", "10"],
    ["y", "12", "w", "80"],
    ["h", "30", "text", ""],
  ])
}

pub fn inspector_reports_resolved_geometry_for_column_children_test() {
  let view =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", campy_view.VInt(600)),
      #("h", campy_view.VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      campy_view.node("label", "a")
        |> campy_view.with_props([
          #("h", campy_view.VInt(20)),
          #("text", VText("A")),
        ]),
      campy_view.node("label", "b")
        |> campy_view.with_props([
          #("h", campy_view.VInt(20)),
          #("text", VText("B")),
        ]),
    ])

  let state =
    model.new(
      campy_project.Project(
        title: "Demo",
        modules: [
          campy_project.Module(
            slug: "main",
            form: campy_view.Document(schema: 1, view: view, extra: []),
            handlers: "",
          ),
        ],
        extra: [],
      ),
    )
    |> model.select_controls(["b"])

  campy_ide_wx.inspector_rows(state)
  |> should.equal([
    ["Field", "Value", "Field", "Value"],
    ["id", "b", "kind", "label"],
    ["parent", "root", "x", "0"],
    ["y", "24", "w", "600"],
    ["h", "20", "text", "B"],
  ])
}

// --- T2.3: inspector and events -------------------------------------------

fn state_from(view: campy_view.Node, selection: List(String)) -> model.State {
  model.new(
    campy_project.Project(
      title: "Demo",
      modules: [
        campy_project.Module(
          slug: "main",
          form: campy_view.Document(schema: 1, view: view, extra: []),
          handlers: "",
        ),
      ],
      extra: [],
    ),
  )
  |> model.select_controls(selection)
}

fn design_form(children: List(campy_view.Node)) -> campy_view.Node {
  campy_view.node("form", "root")
  |> campy_view.with_props([
    #("w", VInt(600)),
    #("h", VInt(400)),
  ])
  |> campy_view.with_children(children)
}

fn sized_button(id: String, text: String, x: Int, y: Int) -> campy_view.Node {
  campy_view.node("button", id)
  |> campy_view.with_props([
    #("x", VInt(x)),
    #("y", VInt(y)),
    #("w", VInt(80)),
    #("h", VInt(30)),
    #("text", VText(text)),
  ])
  |> campy_view.with_events(["click"])
}

pub fn inspector_reports_absolute_geometry_for_nested_controls_test() {
  let view =
    design_form([
      campy_view.node("panel", "panel")
      |> campy_view.with_props([
        #("x", VInt(100)),
        #("y", VInt(80)),
        #("w", VInt(300)),
        #("h", VInt(200)),
      ])
      |> campy_view.with_child(sized_button("ok", "Go", 20, 20)),
    ])

  campy_ide_wx.inspector_rows(state_from(view, ["ok"]))
  |> should.equal([
    ["Field", "Value", "Field", "Value"],
    ["id", "ok", "kind", "button"],
    ["parent", "panel", "x", "120"],
    ["y", "100", "w", "80"],
    ["h", "30", "text", "Go"],
  ])
}

pub fn multi_selection_shows_common_values_and_blanks_the_rest_test() {
  let view =
    design_form([
      sized_button("first", "Go", 10, 20),
      sized_button("second", "Stop", 120, 20),
    ])

  campy_ide_wx.inspector_rows(state_from(view, ["first", "second"]))
  |> should.equal([
    ["Field", "Value", "Field", "Value"],
    ["selected", "2", "kind", "button"],
    ["parent", "root", "x", ""],
    ["y", "20", "w", "80"],
    ["h", "30", "text", ""],
  ])
}

pub fn events_list_follows_the_selected_control_test() {
  let view =
    design_form([
      sized_button("ok", "Go", 10, 10),
      campy_view.node("text", "name")
        |> campy_view.with_props([#("text", VText(""))])
        |> campy_view.with_events(["change"]),
    ])

  campy_ide_wx.event_items(state_from(view, [])) |> should.equal([])
  campy_ide_wx.event_items(state_from(view, ["ok"]))
  |> should.equal(["click"])
  campy_ide_wx.event_items(state_from(view, ["ok", "name"]))
  |> should.equal([])
}

pub fn page_index_tracks_form_code_and_source_test() {
  let state = model.new(project())
  campy_ide_wx.page_index(state) |> should.equal(0)

  let code = model.update(state, model.ToggleCodeView)
  campy_ide_wx.page_index(code) |> should.equal(1)

  let source = model.update(code, model.ToggleSourceView)
  campy_ide_wx.page_index(source) |> should.equal(2)
  source.source_view |> should.be_true()
  source.code_view |> should.be_false()

  let form = model.update(source, model.ToggleSourceView)
  campy_ide_wx.page_index(form) |> should.equal(0)
}

pub fn source_text_is_generated_for_the_active_module_test() {
  let state = model.new(project())
  let source = campy_ide_wx.source_text(state)

  string.contains(source, "modules/greeter/form.json") |> should.be_true()
  string.contains(source, "pub fn view() -> Node") |> should.be_true()
  string.contains(source, "campy_view.node(\"form\", \"root\")")
  |> should.be_true()
}

pub fn source_text_changes_when_the_form_changes_test() {
  let state = model.new(project())
  let before = campy_ide_wx.source_text(state)
  let assert Ok(module) = model.active_module(state)

  let edited =
    campy_view.node("form", "root")
    |> campy_view.with_props([#("title", VText("Edited in T2.4"))])
    |> campy_view.with_children([
      campy_view.node("label", "hello")
      |> campy_view.with_props([#("text", VText("Changed"))]),
    ])

  let state = model.commit_view(state, module, edited)
  let after = campy_ide_wx.source_text(state)
  let unchanged = after == before
  unchanged |> should.be_false()
  string.contains(after, "Edited in T2.4") |> should.be_true()
  string.contains(after, "Changed") |> should.be_true()
}
