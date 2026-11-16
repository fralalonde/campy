import campy_project
import campy_view.{VInt, VText}
import campy_view/codec.{JInt, JObject, JString}
import gleam/string
import gleeunit
import gleeunit/should

@external(erlang, "campy_project_test_ffi", "temp_dir")
fn temp_dir() -> String

@external(erlang, "campy_project_test_ffi", "remove_dir")
fn remove_dir(dir: String) -> Nil

@external(erlang, "campy_project_test_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "campy_project_test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

pub fn main() {
  gleeunit.main()
}

fn form(title: String) -> campy_view.Document {
  let view =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("h", VInt(480)),
      #("layout", VText("column")),
      #("title", VText(title)),
      #("w", VInt(640)),
    ])
    |> campy_view.with_children([
      campy_view.node("label", "hello")
      |> campy_view.with_props([#("text", VText("Hello"))]),
    ])
    |> campy_view.normalize

  campy_view.Document(schema: 1, view: view, extra: [])
}

fn module(slug: String, title: String) -> campy_project.Module {
  campy_project.Module(
    slug: slug,
    form: form(title),
    handlers: "pub fn start() {\n  Nil\n}\n",
  )
}

fn project() -> campy_project.Project {
  campy_project.Project(
    title: "Cat Café",
    modules: [
      module("cat_cafe", "Cat Café"),
      module("ccl_widgets", "Widgets"),
    ],
    extra: [],
  )
}

fn error_of(result: Result(a, String)) -> String {
  let assert Error(message) = result
  message
}

pub fn save_and_load_round_trip_test() {
  let dir = temp_dir()
  let expected = project()

  campy_project.save(expected, dir) |> should.equal(Ok(Nil))
  campy_project.load(dir) |> should.equal(Ok(expected))
  remove_dir(dir)
}

pub fn manifest_is_canonical_text_test() {
  let dir = temp_dir()

  campy_project.save(project(), dir) |> should.equal(Ok(Nil))

  read_file(dir <> "/campy.json")
  |> should.equal(Ok(
    "{
  \"schema\": 1,
  \"title\": \"Cat Café\",
  \"modules\": [
    \"cat_cafe\",
    \"ccl_widgets\"
  ]
}
",
  ))

  remove_dir(dir)
}

pub fn form_file_is_canonical_json_test() {
  let dir = temp_dir()

  campy_project.save(project(), dir) |> should.equal(Ok(Nil))

  let assert Ok(form) = read_file(dir <> "/modules/cat_cafe/form.json")
  form
  |> string.starts_with("{\n  \"schema\": 1,\n  \"view\": {")
  |> should.be_true()
  form |> string.contains("\"kind\": \"form\"") |> should.be_true()

  remove_dir(dir)
}

pub fn unknown_project_fields_survive_test() {
  let dir = temp_dir()
  let project =
    campy_project.Project(title: "Cat Café", modules: [], extra: [
      #("future", JObject([#("x", JInt(1))])),
    ])

  campy_project.save(project, dir) |> should.equal(Ok(Nil))
  campy_project.load(dir) |> should.equal(Ok(project))

  let assert Ok(manifest) = read_file(dir <> "/campy.json")
  manifest |> string.contains("\"future\"") |> should.be_true()

  remove_dir(dir)
}

pub fn newer_schema_is_refused_test() {
  let dir = temp_dir()

  write_file(
    dir <> "/campy.json",
    "{\"schema\":2,\"title\":\"X\",\"modules\":[]}",
  )
  |> should.equal(Ok(Nil))

  campy_project.load(dir)
  |> error_of
  |> should.equal("unsupported project schema: 2")

  remove_dir(dir)
}

pub fn missing_project_is_an_error_test() {
  let dir = temp_dir()

  campy_project.load(dir)
  |> error_of
  |> string.contains("campy.json")
  |> should.be_true()

  remove_dir(dir)
}

pub fn duplicate_module_slug_is_rejected_test() {
  let project =
    campy_project.Project(
      title: "X",
      modules: [module("a", "A"), module("a", "B")],
      extra: [],
    )

  campy_project.save(project, temp_dir())
  |> error_of
  |> should.equal("duplicate module slug: a")
}

pub fn invalid_module_slug_is_rejected_test() {
  let project =
    campy_project.Project(
      title: "X",
      modules: [module("Cat Cafe", "A")],
      extra: [],
    )

  campy_project.save(project, temp_dir())
  |> error_of
  |> should.equal("invalid module slug: Cat Cafe")
}

pub fn handler_files_round_trip_verbatim_test() {
  let dir = temp_dir()
  let project =
    campy_project.Project(
      title: "X",
      modules: [
        campy_project.Module(
          slug: "one",
          form: form("One"),
          handlers: "// exact text\npub fn go() { Nil }",
        ),
      ],
      extra: [],
    )

  campy_project.save(project, dir) |> should.equal(Ok(Nil))

  read_file(dir <> "/modules/one/handlers.gleam")
  |> should.equal(Ok("// exact text\npub fn go() { Nil }"))

  remove_dir(dir)
}

pub fn handler_name_is_control_underscore_event_test() {
  campy_project.handler_name("save_button", "click")
  |> should.equal("save_button_click")
}

pub fn module_lookup_test() {
  case campy_project.module(project(), "cat_cafe") {
    Ok(found) -> found.slug |> should.equal("cat_cafe")
    Error(error) -> error |> should.equal("unexpected")
  }
}

pub fn module_lookup_missing_test() {
  campy_project.module(project(), "nope")
  |> error_of
  |> should.equal("no such module: nope")
}

pub fn extras_are_kept_as_json_test() {
  let project =
    campy_project.Project(title: "X", modules: [], extra: [
      #("note", JString("hi")),
    ])

  project.extra
  |> should.equal([#("note", JString("hi"))])
}
