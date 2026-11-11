import campy_form
import campy_form/preview
import campy_form/project
import campy_form/syntax
import campy_form/workspace
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn add_control_assigns_unique_names_and_positions_test() {
  let #(form, first) =
    campy_form.add_control(campy_form.new_form(), campy_form.Button, "")
  let #(form, second) = campy_form.add_control(form, campy_form.Button, "")
  first.name |> should.equal("button1")
  first.id |> should.equal("button-1")
  second.name |> should.equal("button2")
  second.y |> should.equal(24 + 44)
  list.length(form.controls) |> should.equal(2)
}

pub fn rejects_duplicate_and_invalid_names_test() {
  let duplicate =
    campy_form.Form(
      "campy.form",
      "x",
      320,
      200,
      campy_form.Free,
      [
        campy_form.Control(
          "a",
          "same",
          campy_form.Label,
          0,
          0,
          10,
          10,
          "x",
          True,
          True,
        ),
        campy_form.Control(
          "b",
          "same",
          campy_form.Label,
          0,
          0,
          10,
          10,
          "y",
          True,
          True,
        ),
      ],
      [],
      [],
    )
  campy_form.validate(duplicate) |> should.be_error
  let invalid =
    campy_form.Form(
      "campy.form",
      "x",
      320,
      200,
      campy_form.Free,
      [
        campy_form.Control(
          "a",
          "1bad",
          campy_form.Label,
          0,
          0,
          10,
          10,
          "x",
          True,
          True,
        ),
      ],
      [],
      [],
    )
  campy_form.validate(invalid) |> should.be_error
}

pub fn handler_names_follow_control_names_test() {
  campy_form.Control(
    "b",
    "save_button",
    campy_form.Button,
    0,
    0,
    1,
    1,
    "x",
    True,
    True,
  )
  |> campy_form.handler_name
  |> should.equal(Some("save_button_clicked"))
  campy_form.Control(
    "e",
    "email",
    campy_form.EditBox,
    0,
    0,
    1,
    1,
    "",
    True,
    True,
  )
  |> campy_form.handler_name
  |> should.equal(Some("email_changed"))
  campy_form.Control(
    "l",
    "caption",
    campy_form.Label,
    0,
    0,
    1,
    1,
    "x",
    True,
    True,
  )
  |> campy_form.handler_name
  |> should.equal(None)
}

pub fn ensure_handler_is_idempotent_test() {
  let source = campy_form.default_source()
  let #(once, start) = campy_form.ensure_handler(source, "button1_clicked")
  string.contains(once, "pub fn button1_clicked() -> Nil") |> should.be_true
  string.contains(once, "TODO: implement button1_clicked") |> should.be_true
  let #(twice, again) = campy_form.ensure_handler(once, "button1_clicked")
  twice |> should.equal(once)
  again |> should.equal(start)
}

pub fn handler_replace_updates_only_the_block_test() {
  let #(source, start) =
    campy_form.ensure_handler(campy_form.default_source(), "button1_clicked")
  let assert Some(range) = campy_form.handler_range(source, start)
  let text = campy_form.handler_text(source, range)
  string.contains(text, "TODO") |> should.be_true
  let replacement = "pub fn button1_clicked() -> Nil {\n  Nil\n}"
  let #(next, next_range) =
    campy_form.replace_handler(source, range, replacement)
  string.contains(next, "TODO") |> should.be_false
  string.contains(next, "// Campy event handlers.") |> should.be_true
  let assert Some(checked) = campy_form.handler_range(next, start)
  next_range |> should.equal(checked)
}

pub fn tokenizer_preserves_source_text_test() {
  let line = "  let x = \"a\\\"b\" // done"
  syntax.tokenize(line)
  |> list.map(fn(token) {
    case token {
      syntax.Token(_, text) -> text
    }
  })
  |> string.concat
  |> should.equal(line)
}

pub fn tokenizer_classifies_keywords_strings_and_comments_test() {
  let assert [
    syntax.Token(syntax.Keyword, "pub"),
    syntax.Token(syntax.Space, " "),
    ..rest
  ] = syntax.tokenize("pub fn main() {")
  let kinds =
    list.map(rest, fn(token) {
      case token {
        syntax.Token(kind, _) -> kind
      }
    })
  list.contains(kinds, syntax.Keyword) |> should.be_true
  syntax.tokenize("// hello")
  |> should.equal([syntax.Token(syntax.Comment, "// hello")])
  syntax.tokenize("\"text\"")
  |> should.equal([syntax.Token(syntax.Str, "\"text\"")])
}

pub fn preview_emits_window_controls_and_callbacks_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "A \"title\" \\{x}",
      320,
      200,
      campy_form.Free,
      [
        campy_form.Control(
          "button-1",
          "save",
          campy_form.Button,
          10,
          12,
          80,
          30,
          "Save \"now\"",
          True,
          True,
        ),
        campy_form.Control(
          "edit-1",
          "email",
          campy_form.EditBox,
          10,
          60,
          120,
          30,
          "",
          True,
          True,
        ),
        campy_form.Control(
          "label-1",
          "caption",
          campy_form.Label,
          10,
          100,
          120,
          20,
          "Hi",
          True,
          True,
        ),
      ],
      [],
      [],
    )
  let assert Ok(source) = preview.to_slint(form)
  string.contains(source, "export component CampyPreview inherits Window")
  |> should.be_true
  string.contains(source, "callback save_clicked();") |> should.be_true
  string.contains(source, "callback email_changed(string);") |> should.be_true
  string.contains(source, "clicked => { root.save_clicked(); }")
  |> should.be_true
  string.contains(source, "title: \"A \\\"title\\\" \\\\{x}\";")
  |> should.be_true
  string.contains(source, "text: \"Save \\\"now\\\"\";") |> should.be_true
}

pub fn workspace_roundtrip_test() {
  let ws = workspace.new(project.campy())
  workspace.count(ws) |> should.equal(1)
  let path = "/tmp/campy-workspace-test.campy"
  let assert Ok(saved) = workspace.save_at(ws, path)
  workspace.count(saved) |> should.equal(1)
  let assert Ok(loaded) = workspace.load(path)
  workspace.count(loaded) |> should.equal(1)
  loaded.active |> should.equal("projects/campy.campy")
  let assert Some(active) = workspace.active_project(loaded)
  active.title |> should.equal("Campy")
}

pub fn render_order_puts_containers_before_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "x",
      320,
      200,
      campy_form.Free,
      [
        campy_form.Control(
          "button-1",
          "button1",
          campy_form.Button,
          10,
          10,
          80,
          30,
          "B",
          True,
          True,
        ),
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          0,
          0,
          200,
          200,
          "P",
          True,
          True,
        ),
      ],
      [#("button-1", "panel-1")],
      [],
    )
  campy_form.render_controls(form)
  |> list.map(fn(control) { control.id })
  |> should.equal(["panel-1", "button-1"])
}

pub fn set_parent_refuses_cycles_and_missing_parents_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "x",
      320,
      200,
      campy_form.Free,
      [
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          0,
          0,
          200,
          200,
          "P",
          True,
          True,
        ),
        campy_form.Control(
          "panel-2",
          "panel2",
          campy_form.Panel,
          10,
          10,
          100,
          100,
          "P2",
          True,
          True,
        ),
      ],
      [#("panel-2", "panel-1")],
      [],
    )
  let next = campy_form.set_parent(form, "panel-1", "panel-2")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
  let next = campy_form.set_parent(form, "panel-1", "missing")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
  let next = campy_form.set_parent(form, "panel-1", "panel-2")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
}

pub fn aligned_controls_follow_the_window_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Aligned",
      400,
      300,
      campy_form.Free,
      [
        campy_form.Control(
          "button-1",
          "save",
          campy_form.Button,
          10,
          10,
          80,
          30,
          "Save",
          True,
          True,
        ),
      ],
      [],
      [#("button-1", campy_form.Bottom)],
    )
  let assert Ok(source) = preview.to_slint(form)
  string.contains(source, "y: parent.height - 30px") |> should.be_true
  string.contains(source, "width: parent.width") |> should.be_true
}

pub fn project_roundtrip_preserves_modules_test() {
  let path = "/tmp/campy-form-roundtrip-test.campy"
  let original = project.campy()
  let assert Ok(saved) = project.save(original, path)
  saved.path |> should.equal(path)
  let assert Ok(loaded) = project.load(path)
  loaded.version |> should.equal(5)
  loaded.title |> should.equal("Campy")
  loaded.modules
  |> list.map(fn(module) { module.name })
  |> should.equal(["Cat Café", "Widgets", "Welcome", "Search box"])
  let assert [first, second, third, fourth] = loaded.modules
  first.form.title |> should.equal("Cat Café")
  list.length(first.form.controls) |> should.equal(7)
  list.length(first.form.parents) |> should.equal(6)
  second.form.title |> should.equal("Widgets")
  list.length(second.form.controls) |> should.equal(12)
  list.length(second.form.aligns) |> should.equal(2)
  string.contains(third.source, "button1_clicked") |> should.be_true
  fourth.form.title |> should.equal("Search box")
  list.length(fourth.form.controls) |> should.equal(3)
}

pub fn project_module_operations_test() {
  let project = project.campy()
  list.length(project.modules) |> should.equal(4)
  project.find_module(project, "welcome")
  |> should.be_some
  project.find_module(project, "missing")
  |> should.be_none

  let assert Some(module) = project.find_module(project, "search-box")
  let renamed =
    project.update_module(project, project.Module(..module, name: "Lookup"))
  let assert Some(updated) = project.find_module(renamed, "search-box")
  updated.name |> should.equal("Lookup")

  let added =
    project.add_module(
      project,
      project.Module(
        "extra",
        "Extra",
        campy_form.new_form(),
        campy_form.default_source(),
      ),
    )
  list.length(added.modules) |> should.equal(5)
  list.length(project.remove_module(added, "extra").modules)
  |> should.equal(4)
}

pub fn project_load_reports_missing_files_test() {
  project.load("/tmp/campy-does-not-exist-42.campy")
  |> should.be_error
}

pub fn form_defaults_are_sane_test() {
  let form = campy_form.new_form()
  form.width |> should.equal(640)
  int.to_string(form.height) |> should.equal("420")
  form.controls |> should.equal([])
}
