import campy_form
import campy_form/canora
import campy_form/project
import campy_form/syntax
import campy_form/workspace
import gleam/int
import gleam/list
import gleam/option.{Some}
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
          [],
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
          [],
        ),
      ],
      [],
      [],
      [],
      [],
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
          [],
        ),
      ],
      [],
      [],
      [],
      [],
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
    [],
  )
  |> campy_form.handler_name("clicked")
  |> should.equal("save_button_clicked")
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
    [],
  )
  |> campy_form.handler_name("edited")
  |> should.equal("email_edited")
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
    [],
  )
  |> campy_form.handler_name("clicked")
  |> should.equal("caption_clicked")
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

pub fn workspace_roundtrip_test() {
  let ws = workspace.new(project.campy())
  workspace.count(ws) |> should.equal(1)
  let path = "/tmp/campy-workspace-test.campy"
  let assert Ok(saved) = workspace.save_at(ws, path)
  workspace.count(saved) |> should.equal(1)
  let assert Ok(loaded) = workspace.load(path)
  workspace.count(loaded) |> should.equal(1)
  loaded.active |> should.equal(project.default_path)
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
          [],
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
          [],
        ),
      ],
      [#("button-1", "panel-1")],
      [],
      [],
      [],
      [],
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
          [],
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
          [],
        ),
      ],
      [#("panel-2", "panel-1")],
      [],
      [],
      [],
      [],
      [],
    )
  let next = campy_form.set_parent(form, "panel-1", "panel-2")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
  let next = campy_form.set_parent(form, "panel-1", "missing")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
  let next = campy_form.set_parent(form, "panel-1", "panel-2")
  campy_form.parent_of(next, "panel-1") |> should.equal("")
}

pub fn project_roundtrip_preserves_modules_test() {
  let path = "/tmp/campy-form-roundtrip-test.campy"
  let original = project.campy()
  let assert Ok(saved) = project.save(original, path)
  saved.path |> should.equal(path)
  let assert Ok(loaded) = project.load(path)
  loaded.version |> should.equal(13)
  loaded.icon |> should.equal("assets/camping-tent.png")
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
  let assert project.Embedded(third_source) = third.source_origin
  string.contains(third_source, "button1_clicked") |> should.be_true
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
        project.Embedded(campy_form.default_source()),
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

pub fn container_layout_arranges_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Panels",
      400,
      300,
      campy_form.Free,
      [
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          20,
          20,
          300,
          200,
          "P",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "a",
          "a",
          campy_form.Button,
          0,
          0,
          50,
          20,
          "A",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "b",
          "b",
          campy_form.Button,
          0,
          0,
          60,
          30,
          "B",
          True,
          True,
          [],
        ),
      ],
      [#("a", "panel-1"), #("b", "panel-1")],
      [],
      [#("panel-1", campy_form.Column)],
      [#("panel-1", 8)],
      [],
      [],
    )
  let #(ax, ay, aw, ah) =
    campy_form.bounds(
      form,
      campy_form.Control(
        "a",
        "a",
        campy_form.Button,
        0,
        0,
        50,
        20,
        "A",
        True,
        True,
        [],
      ),
    )
  ax |> should.equal(28)
  ay |> should.equal(28)
  aw |> should.equal(284)
  ah |> should.equal(20)
  let #(bx, by, bw, bh) =
    campy_form.bounds(
      form,
      campy_form.Control(
        "b",
        "b",
        campy_form.Button,
        0,
        0,
        60,
        30,
        "B",
        True,
        True,
        [],
      ),
    )
  bx |> should.equal(28)
  by |> should.equal(54)
  bw |> should.equal(284)
  bh |> should.equal(30)
  let row = campy_form.set_layout_for(form, "panel-1", campy_form.Row)
  let #(bx2, _, bw2, bh2) =
    campy_form.bounds(
      row,
      campy_form.Control(
        "b",
        "b",
        campy_form.Button,
        0,
        0,
        60,
        30,
        "B",
        True,
        True,
        [],
      ),
    )
  bx2 |> should.equal(84)
  bw2 |> should.equal(60)
  bh2 |> should.equal(184)
}

pub fn border_insets_aligned_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Border",
      400,
      300,
      campy_form.Free,
      [
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          20,
          20,
          300,
          200,
          "P",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "client",
          "client",
          campy_form.Button,
          0,
          0,
          50,
          20,
          "C",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "bottom",
          "bottom",
          campy_form.Button,
          0,
          0,
          50,
          20,
          "B",
          True,
          True,
          [],
        ),
      ],
      [#("client", "panel-1"), #("bottom", "panel-1")],
      [#("client", campy_form.Client), #("bottom", campy_form.Bottom)],
      [],
      [#("panel-1", 10)],
      [],
      [],
    )
  let #(cx, cy, cw, ch) =
    campy_form.bounds(
      form,
      campy_form.Control(
        "client",
        "client",
        campy_form.Button,
        0,
        0,
        50,
        20,
        "C",
        True,
        True,
        [],
      ),
    )
  // The bottom child takes its 20px band out of the client area: the two must
  // not overlap.
  #(cx, cy, cw, ch) |> should.equal(#(30, 30, 280, 160))
  let #(bx, by, bw, bh) =
    campy_form.bounds(
      form,
      campy_form.Control(
        "bottom",
        "bottom",
        campy_form.Button,
        0,
        0,
        50,
        20,
        "B",
        True,
        True,
        [],
      ),
    )
  #(bx, by, bw, bh) |> should.equal(#(30, 190, 280, 20))
}

pub fn fill_uses_space_between_siblings_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Fill",
      400,
      300,
      campy_form.Free,
      [
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          0,
          0,
          300,
          200,
          "P",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "header",
          "header",
          campy_form.Label,
          0,
          0,
          100,
          20,
          "H",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "footer",
          "footer",
          campy_form.Label,
          0,
          0,
          100,
          20,
          "F",
          True,
          True,
          [],
        ),
        campy_form.Control(
          "fill",
          "fill",
          campy_form.Button,
          20,
          80,
          50,
          30,
          "Fill",
          True,
          True,
          [],
        ),
      ],
      [
        #("header", "panel-1"),
        #("footer", "panel-1"),
        #("fill", "panel-1"),
      ],
      [
        #("header", campy_form.Top),
        #("footer", campy_form.Bottom),
        #("fill", campy_form.Fill),
      ],
      [],
      [#("panel-1", 10)],
      [],
      [],
    )
  let #(x, y, w, h) =
    campy_form.bounds(
      form,
      campy_form.Control(
        "fill",
        "fill",
        campy_form.Button,
        20,
        80,
        50,
        30,
        "Fill",
        True,
        True,
        [],
      ),
    )
  #(x, y, w, h) |> should.equal(#(10, 30, 280, 140))
}

// Z-order: siblings render in controls-list order, so bring-to-front moves a
// control after its overlapping siblings and send-to-back before them.
pub fn bring_to_front_reorders_siblings_test() {
  let form = overlapping_form()
  let ordered =
    campy_form.render_controls(form)
    |> list.map(fn(control) { control.id })
  ordered |> should.equal(["panel-1", "under", "over"])

  let front =
    campy_form.render_controls(campy_form.bring_to_front(form, ["under"]))
    |> list.map(fn(control) { control.id })
  front |> should.equal(["panel-1", "over", "under"])

  // Send-to-back moves "over" below its sibling "under"; it still renders
  // after its parent panel (children draw within their container).
  let back =
    campy_form.render_controls(campy_form.send_to_back(form, ["over"]))
    |> list.map(fn(control) { control.id })
  back |> should.equal(["panel-1", "over", "under"])
}

// A moved container keeps its subtree: children still render after their parent.
pub fn reordering_keeps_children_with_parents_test() {
  let form = overlapping_form()
  let back = campy_form.send_to_back(form, ["panel-1"])
  let ordered =
    campy_form.render_controls(back)
    |> list.map(fn(control) { control.id })
  ordered
  |> should.equal(["panel-1", "under", "over"])
}

// Transparency: 0 is opaque (and dropped from the map), values clamp to 0..100.
pub fn transparency_accessors_test() {
  let form = overlapping_form()
  campy_form.transparency_of(form, "under") |> should.equal(0)

  let set =
    form
    |> campy_form.set_transparency_for("under", 60)
    |> campy_form.set_transparency_for("under", 200)
  campy_form.transparency_of(set, "under") |> should.equal(100)

  let cleared = campy_form.set_transparency_for(set, "under", 0)
  campy_form.transparency_of(cleared, "under") |> should.equal(0)
  cleared.transparencies |> should.equal([])
}

fn overlapping_form() -> campy_form.Form {
  campy_form.Form(
    "campy.form",
    "Overlapping",
    400,
    300,
    campy_form.Free,
    [
      campy_form.Control(
        "panel-1",
        "panel1",
        campy_form.Panel,
        10,
        10,
        380,
        280,
        "P",
        True,
        True,
        [],
      ),
      campy_form.Control(
        "under",
        "under",
        campy_form.Button,
        40,
        40,
        120,
        32,
        "Under",
        True,
        True,
        [],
      ),
      campy_form.Control(
        "over",
        "over",
        campy_form.Button,
        60,
        40,
        120,
        32,
        "Over",
        True,
        True,
        [],
      ),
    ],
    [#("under", "panel-1"), #("over", "panel-1")],
    [],
    [],
    [],
    [],
    [],
  )
}

// Transparency survives a save/load roundtrip through the project codec.
pub fn transparency_roundtrip_test() {
  let path = "/tmp/campy-form-transparency-test.campy"
  let assert [first, ..] = project.campy().modules
  let updated =
    project.Module(
      ..first,
      form: campy_form.set_transparency_for(first.form, "picture-1", 45),
    )
  let assert Ok(_saved) =
    project.save(project.update_module(project.campy(), updated), path)
  let assert Ok(loaded) = project.load(path)
  let assert [first, ..] = loaded.modules
  campy_form.transparency_of(first.form, "picture-1") |> should.equal(45)
}

// --- v12 source origins -----------------------------------------------------

fn external_project(path: String) -> project.Project {
  project.Project(
    project.version,
    "External",
    [
      project.Module(
        "handlers",
        "Handlers",
        campy_form.new_form(),
        project.External(path),
      ),
    ],
    "/tmp/external.campy",
    "",
    "",
  )
}

// An External module stores only its path: loading never reads the file (this
// path does not exist), just like the IDE reads it later on open.
pub fn external_module_roundtrip_stores_only_the_path_test() {
  let path = "/tmp/campy-form-external-test.campy"
  let original = external_project("src/handlers_cat_cafe.gleam")
  let assert Ok(_saved) = project.save(original, path)
  let assert Ok(loaded) = project.load(path)
  let assert [module] = loaded.modules
  module.source_origin
  |> should.equal(project.External("src/handlers_cat_cafe.gleam"))
}

pub fn external_module_keeps_absolute_paths_test() {
  let path = "/tmp/campy-form-external-absolute-test.campy"
  let absolute = "/workspace/campy/src/handlers.gleam"
  let assert Ok(_saved) = project.save(external_project(absolute), path)
  let assert Ok(loaded) = project.load(path)
  let assert [module] = loaded.modules
  module.source_origin |> should.equal(project.External(absolute))
}

// A project mixes embedded sources (the demo) and external ones (dogfood);
// both origins survive the round trip unchanged.
pub fn mixed_source_origins_roundtrip_test() {
  let path = "/tmp/campy-form-mixed-origins-test.campy"
  let original =
    project.add_module(
      project.campy(),
      project.Module(
        "dogfood",
        "Dogfood",
        campy_form.new_form(),
        project.External("gleam/apps/campy_ide/src/campy_ide.gleam"),
      ),
    )
  let assert Ok(_saved) = project.save(original, path)
  let assert Ok(loaded) = project.load(path)
  let assert project.External(dogfood_path) = module_origin(loaded, "dogfood")
  dogfood_path
  |> should.equal("gleam/apps/campy_ide/src/campy_ide.gleam")
  let assert project.Embedded(cat_source) = module_origin(loaded, "cat-cafe")
  string.contains(cat_source, "pet_button_clicked") |> should.be_true
}

fn module_origin(loaded: project.Project, id: String) -> project.SourceOrigin {
  let assert Some(module) = project.find_module(loaded, id)
  module.source_origin
}

pub fn empty_external_source_path_is_rejected_test() {
  let path = "/tmp/campy-form-empty-external-test.campy"
  let assert Ok(_saved) = project.save(external_project(""), path)
  case project.load(path) {
    Ok(_) -> should.fail()
    Error(message) ->
      string.contains(message, "has an empty external source path")
      |> should.be_true()
  }
}

// A v12 file (no default module) still loads: dropping a whole project over a
// field the codec can default is worse than one migration step.
pub fn a_v12_project_loads_with_no_default_module_test() {
  let assert Ok(loaded) =
    project.load("gleam/packages/campy_form/test/fixtures/project-v12.campy")
  loaded.version |> should.equal(13)
  loaded.default_module |> should.equal("")
  // Everything else is the same project.
  loaded.title |> should.equal("Campy")
  loaded.modules
  |> list.map(fn(module) { module.name })
  |> should.equal(["Cat Café", "Widgets", "Welcome", "Search box"])
}

// Older versions have no upgrade chain: an older version tag is an explicit
// error.
pub fn legacy_project_version_is_rejected_test() {
  let path = "/tmp/campy-form-legacy-version-test.campy"
  let legacy = project.Project(..project.campy(), version: 11)
  let assert Ok(_saved) = project.save(legacy, path)
  project.load(path)
  |> should.equal(Error("Unsupported project version"))
}

// The checked-in demo is the codec's reference file: it loads at v13 and is
// exactly what `project.campy()` builds (path aside).
pub fn client_fills_what_the_border_siblings_leave_test() {
  // A form with a top bar, a bottom bar and a left rail: alClient is what is
  // left of the middle.
  let form = campy_form.new_form()
  let #(form, top) = campy_form.add_control(form, campy_form.Panel, "")
  let #(form, bottom) = campy_form.add_control(form, campy_form.Panel, "")
  let #(form, left) = campy_form.add_control(form, campy_form.Panel, "")
  let #(form, client) = campy_form.add_control(form, campy_form.Panel, "")
  let sizes = [
    #(top.id, 0, 0, form.width, 40, campy_form.Top),
    #(bottom.id, 0, 0, form.width, 30, campy_form.Bottom),
    #(left.id, 0, 0, 60, 0, campy_form.Left),
    #(client.id, 0, 0, 0, 0, campy_form.Client),
  ]
  let form =
    list.fold(sizes, form, fn(acc, entry) {
      let #(id, x, y, w, h, align) = entry
      let acc = campy_form.set_align(acc, id, align)
      campy_form.update_control(
        acc,
        campy_form.Control(
          ..assert_control(acc, id),
          x: x,
          y: y,
          width: w,
          height: h,
        ),
      )
    })
  let client = assert_control(form, client.id)
  let #(x, y, w, h) = campy_form.bounds(form, client)
  // Border: 0, so the inner rect is the form itself.
  #(x, y, w, h)
  |> should.equal(#(60, 40, form.width - 60, form.height - 40 - 30))
}

fn assert_control(form: campy_form.Form, id: String) -> campy_form.Control {
  let assert Some(control) = campy_form.find_control(form, id)
  control
}

pub fn the_canora_demo_project_roundtrips_test() {
  let path = "/tmp/canora-roundtrip.campy"
  let demo = canora.project()
  demo.default_module |> should.equal("library")
  let assert Ok(_saved) = project.save(demo, path)
  let assert Ok(loaded) = project.load(path)
  loaded.modules
  |> list.map(fn(module) { module.name })
  |> should.equal(["Library", "Search", "Player", "Services"])
  // The non-visual components are part of the forms, with their properties.
  let assert Some(library) = project.find_module(loaded, "library")
  let timers =
    list.filter(library.form.controls, fn(control) {
      control.kind == campy_form.Timer
    })
  let datasources =
    list.filter(library.form.controls, fn(control) {
      control.kind == campy_form.Datasource
    })
  list.length(timers) |> should.equal(1)
  list.length(datasources) |> should.equal(1)
  let assert [timer, ..] = timers
  campy_form.control_prop(timer, "target", "") |> should.equal("progress")
  // The page is free-layout: the panels are backgrounds and every child sits
  // where it belongs on the page (the client/border model has its own tests).
  library.form.aligns |> should.equal([])
  // Tidal is a provider like Spotify: the Services module points a datasource
  // at the Tidal catalogue and carries the token field that would unlock it.
  let assert Some(services) = project.find_module(loaded, "connect")
  let urls =
    list.filter(services.form.controls, fn(control) {
      control.kind == campy_form.Datasource
    })
    |> list.map(fn(control) { campy_form.control_prop(control, "url", "") })
  urls |> should.equal(["assets/canora/tidal.json"])
  services.form.controls
  |> list.any(fn(control) { control.name == "provider" })
  |> should.be_true
}

pub fn checked_in_campy_project_is_the_current_demo_test() {
  let loaded = case project.load("campy.campy") {
    Ok(loaded) -> loaded
    Error(_) ->
      case project.load("../../../campy.campy") {
        Ok(loaded) -> loaded
        Error(error) -> panic as { "cannot load campy.campy: " <> error }
      }
  }
  loaded.version |> should.equal(13)
  project.Project(..loaded, path: project.default_path)
  |> should.equal(project.campy())
  let assert [first, ..] = loaded.modules
  let assert project.Embedded(source) = first.source_origin
  string.contains(source, "pet_button_clicked") |> should.be_true
}
