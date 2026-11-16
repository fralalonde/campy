import campy_ide_model as model
import campy_ide_wx
import campy_project
import campy_view.{VText}
import campy_wx/plan.{TreeItem}
import gleam/list
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
    ["Field", "Value"],
    ["Project", "Demo"],
    ["Module", "greeter"],
    ["Tabs", "1"],
    ["History", "0"],
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
