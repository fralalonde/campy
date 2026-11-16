import campy_ide_model
import campy_project
import campy_view.{VText}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
