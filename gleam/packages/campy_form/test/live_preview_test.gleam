import campy_bridge.{
  type ControlDesc, type WireValue, WireBool, WireFloat, WireImage, WireInt,
  WireList, WireStruct, WireText,
}
import campy_form
import campy_form/live_preview
import campy_form/project
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// --- Golden: the checked-in Cat Café document ------------------------------

const fixture_path = "test/fixtures/cat_cafe_controls.txt"

const fixture_header =
  "# Cat Café form → ControlDesc document (golden, Z2.1).\n"
  <> "# One node per line, children indented: kind id= text= xy= wh= enabled= visible= props=.\n"
  <> "# Regenerate after a deliberate emitter change: CAMPY_UPDATE_FIXTURE=1 gleam test\n"

// Run with `CAMPY_UPDATE_FIXTURE=1 gleam test` to rewrite the fixture after a
// deliberate emitter change; the checked-in file is what the test compares.
pub fn cat_cafe_document_matches_fixture_test() {
  let assert [cat_cafe, ..] = project.campy().modules
  let rendered = cat_cafe.form |> live_preview.to_controls |> describe
  case update_fixture() {
    True -> write_fixture(fixture_path, fixture_header <> rendered <> "\n")
    False -> {
      let assert Ok(expected) = read_fixture(fixture_path)
      rendered |> should.equal(strip_comments(expected))
    }
  }
}

fn strip_comments(contents: String) -> String {
  contents
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(line, "#") })
  |> string.join("\n")
  |> string.trim
}

// The Cat Café form is a Free form with one panel adopting six children; the
// document nests them, so the panel is the root's only child and its own
// children are parent-relative.
pub fn cat_cafe_tree_shape_test() {
  let assert [cat_cafe, ..] = project.campy().modules
  let assert [root] = live_preview.to_controls(cat_cafe.form)
  root.id |> should.equal(live_preview.window_id)
  root.kind |> should.equal("panel")
  root.w |> should.equal(640)
  root.h |> should.equal(420)
  let assert [panel] = root.children
  panel.kind |> should.equal("panel")
  panel.x |> should.equal(24)
  panel.y |> should.equal(24)
  panel.w |> should.equal(560)
  panel.h |> should.equal(360)
  panel.children
  |> list.map(fn(child) { child.kind })
  |> should.equal(["picture", "label", "list", "edit", "button", "button"])
  let assert [picture, ..] = panel.children
  // 44,68 in form coordinates; the panel sits at 24,24.
  picture.x |> should.equal(20)
  picture.y |> should.equal(44)
}

// --- Geometry: Free, Column, Row -------------------------------------------

pub fn free_layout_nests_children_at_parent_relative_geometry_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Free",
      400,
      300,
      campy_form.Free,
      [
        control("panel-1", "panel1", campy_form.Panel, 20, 20, 300, 200, "P"),
        control("a", "a", campy_form.Button, 40, 60, 50, 20, "A"),
        control("b", "b", campy_form.Label, 5, 6, 100, 10, "B"),
      ],
      [#("a", "panel-1")],
      [],
      [],
      [],
      [],
      [],
    )
  let assert [root] = live_preview.to_controls(form)
  root.x |> should.equal(0)
  root.w |> should.equal(400)
  root.children
  |> list.map(fn(desc) { desc.id })
  |> should.equal([
    campy_form.wire_id("panel-1"),
    campy_form.wire_id("b"),
  ])
  let assert [panel, _label] = root.children
  let assert [child] = panel.children
  panel.x |> should.equal(20)
  // The form stores absolute geometry; the document is parent-relative.
  child.x |> should.equal(20)
  child.y |> should.equal(40)
  child.w |> should.equal(50)
  child.h |> should.equal(20)
}

pub fn column_layout_flows_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Column",
      400,
      300,
      campy_form.Column,
      [
        control("a", "a", campy_form.Button, 0, 0, 80, 30, "A"),
        control("b", "b", campy_form.Button, 0, 0, 80, 30, "B"),
      ],
      [],
      [],
      [],
      [#("", 12)],
      [],
      [],
    )
  let assert [root] = live_preview.to_controls(form)
  root.props
  |> should.equal([#("layout", WireText("column")), #("border", WireInt(12))])
  let assert [a, b] = root.children
  // Column children fill the parent's inner width and keep their height.
  a.x |> should.equal(0)
  a.w |> should.equal(376)
  a.h |> should.equal(30)
  b.w |> should.equal(376)
}

pub fn row_layout_flows_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Row",
      400,
      300,
      campy_form.Row,
      [
        control("a", "a", campy_form.Button, 0, 0, 80, 30, "A"),
        control("b", "b", campy_form.Button, 0, 0, 90, 30, "B"),
      ],
      [],
      [],
      [],
      [],
      [],
      [],
    )
  let assert [root] = live_preview.to_controls(form)
  root.props
  |> should.equal([#("layout", WireText("row")), #("border", WireInt(0))])
  let assert [a, b] = root.children
  // Row children keep their width and fill the parent's inner height.
  a.w |> should.equal(80)
  a.h |> should.equal(300)
  b.w |> should.equal(90)
  b.h |> should.equal(300)
}

pub fn nested_column_panel_arranges_children_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Nested",
      400,
      300,
      campy_form.Free,
      [
        control("panel-1", "panel1", campy_form.Panel, 10, 10, 300, 200, "P"),
        control("a", "a", campy_form.Button, 0, 0, 50, 20, "A"),
        control("b", "b", campy_form.Button, 0, 0, 60, 30, "B"),
      ],
      [#("a", "panel-1"), #("b", "panel-1")],
      [],
      [#("panel-1", campy_form.Column)],
      [#("panel-1", 8)],
      [],
      [],
    )
  let assert [root] = live_preview.to_controls(form)
  let assert [panel] = root.children
  panel.props
  |> should.equal([#("layout", WireText("column")), #("border", WireInt(8))])
  let assert [a, b] = panel.children
  // The designer arranges from the panel's inner box (10+8); the document
  // subtracts the panel origin and fills the arranged width.
  a.x |> should.equal(8)
  a.y |> should.equal(8)
  a.w |> should.equal(284)
  a.h |> should.equal(20)
  b.x |> should.equal(8)
  b.y |> should.equal(34)
  b.w |> should.equal(284)
  b.h |> should.equal(30)
}

pub fn aligned_control_follows_the_window_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Aligned",
      400,
      300,
      campy_form.Free,
      [
        control("button-1", "save", campy_form.Button, 10, 10, 80, 30, "Save"),
      ],
      [],
      [#("button-1", campy_form.Bottom)],
      [],
      [],
      [],
      [],
    )
  let assert [root] = live_preview.to_controls(form)
  let assert [save] = root.children
  #(save.x, save.y, save.w, save.h) |> should.equal(#(0, 270, 400, 30))
}

// --- Per-kind prop mapping -------------------------------------------------

pub fn edit_and_memo_props_test() {
  let form =
    single_form([
      control_with_props(
        "edit-1",
        "email",
        campy_form.EditBox,
        0,
        0,
        120,
        30,
        "",
        [#("placeholder", "you@example.com"), #("read-only", "true")],
      ),
      control("memo-1", "memo1", campy_form.Memo, 0, 40, 200, 100, "notes"),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [edit, memo] = root.children
  edit.props
  |> should.equal([
    #("placeholder", WireText("you@example.com")),
    #("read-only", WireBool(True)),
  ])
  memo.props |> should.equal([#("read-only", WireBool(False))])
}

pub fn button_and_menu_props_test() {
  let form =
    single_form([
      control("button-1", "save", campy_form.Button, 0, 0, 80, 30, "Save"),
      control_with_props(
        "menu-1",
        "menu1",
        campy_form.Menu,
        0,
        40,
        120,
        28,
        "File",
        [#("model", "Open, Save, Quit")],
      ),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [save, menu] = root.children
  save.props |> should.equal([#("variant", WireText("solid"))])
  menu.text |> should.equal("File")
  menu.props
  |> should.equal([
    #(
      "model",
      WireList([
        WireText("Open"),
        WireText("Save"),
        WireText("Quit"),
      ]),
    ),
  ])
}

pub fn check_and_radio_props_test() {
  let form =
    single_form([
      control_with_props(
        "check-1",
        "check1",
        campy_form.CheckBox,
        0,
        0,
        150,
        28,
        "Purr",
        [#("checked", "true")],
      ),
      control_with_props(
        "radio-1",
        "radio1",
        campy_form.RadioButton,
        0,
        40,
        150,
        28,
        "Cat",
        [#("group", "species")],
      ),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [check, radio] = root.children
  check.props |> should.equal([#("checked", WireBool(True))])
  radio.props
  |> should.equal([
    #("checked", WireBool(False)),
    #("group", WireText("species")),
  ])
}

pub fn combo_and_list_props_test() {
  let form =
    single_form([
      control_with_props(
        "combo-1",
        "combo1",
        campy_form.ComboBox,
        0,
        0,
        180,
        32,
        "Red, Green , Blue",
        [#("current-index", "1")],
      ),
      // No model: the designer convention falls back to the control's text.
      control(
        "list-1",
        "list1",
        campy_form.ListBox,
        0,
        40,
        200,
        120,
        "Mochi, Taro",
      ),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [combo, list] = root.children
  combo.props
  |> should.equal([
    #("model", WireList([WireText("Red"), WireText("Green"), WireText("Blue")])),
    #("current-index", WireInt(1)),
  ])
  list.props
  |> should.equal([
    #("model", WireList([WireText("Mochi"), WireText("Taro")])),
  ])
}

pub fn slider_and_progress_props_test() {
  let form =
    single_form([
      control_with_props(
        "slider-1",
        "slider1",
        campy_form.Slider,
        0,
        0,
        200,
        32,
        "70",
        [#("minimum", "10"), #("maximum", "90")],
      ),
      control(
        "progress-1",
        "progress1",
        campy_form.Progress,
        0,
        40,
        200,
        24,
        "80",
      ),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [slider, progress] = root.children
  slider.props
  |> should.equal([
    #("minimum", WireInt(10)),
    #("maximum", WireInt(90)),
    #("value", WireInt(70)),
  ])
  progress.props
  |> should.equal([#("value", WireInt(80)), #("maximum", WireInt(100))])
}

pub fn picture_props_test() {
  let form =
    campy_form.set_transparency_for(picture_form(), "pic-1", 60)
    |> campy_form.set_control_prop("pic-1", "fit", "cover")
  let assert [root] = live_preview.to_controls(form)
  let assert [picture] = root.children
  picture.text |> should.equal("assets/cat.png")
  picture.props
  |> should.equal([
    #("source", WireImage("assets/cat.png")),
    #("fit", WireText("cover")),
    #("transparency", WireInt(60)),
  ])

  let assert [plain_root] = live_preview.to_controls(picture_form())
  let assert [plain] = plain_root.children
  plain.props
  |> should.equal([
    #("source", WireImage("assets/cat.png")),
    #("fit", WireText("contain")),
    #("transparency", WireInt(0)),
  ])
}

// The two kinds added with Z2.1 (palette kinds since Z1.1).
pub fn code_editor_props_defaults_test() {
  let #(form, created) =
    campy_form.add_control(campy_form.new_form(), campy_form.CodeEditor, "")
  created.width |> should.equal(400)
  created.height |> should.equal(300)
  campy_form.validate(form) |> should.be_ok
  let assert [root] = live_preview.to_controls(form)
  let assert [editor] = root.children
  editor.kind |> should.equal("code_editor")
  editor.props
  |> should.equal([
    #("language", WireText("gleam")),
    #("read-only", WireBool(False)),
    #("line-numbers", WireBool(True)),
  ])

  let configured =
    campy_form.set_control_prop(form, created.id, "read-only", "true")
  let assert [root] = live_preview.to_controls(configured)
  let assert [editor] = root.children
  editor.props
  |> should.equal([
    #("language", WireText("gleam")),
    #("read-only", WireBool(True)),
    #("line-numbers", WireBool(True)),
  ])
}

pub fn console_props_defaults_test() {
  let #(form, created) =
    campy_form.add_control(campy_form.new_form(), campy_form.Console, "")
  created.width |> should.equal(480)
  created.height |> should.equal(240)
  let assert [root] = live_preview.to_controls(form)
  let assert [console] = root.children
  console.kind |> should.equal("console")
  // The console only carries the universal text row.
  console.props |> should.equal([])
}

pub fn labels_carry_text_not_props_test() {
  let form =
    single_form([
      control("label-1", "caption", campy_form.Label, 3, 4, 120, 20, "Hi"),
    ])
  let assert [root] = live_preview.to_controls(form)
  let assert [label] = root.children
  label.text |> should.equal("Hi")
  label.props |> should.equal([])
}

// --- Wire identity ---------------------------------------------------------

pub fn wire_ids_are_stable_positive_and_unique_test() {
  // A pure function of the control's string id: same id, same wire id.
  let pet = campy_form.wire_id("pet-button")
  let feed = campy_form.wire_id("feed-button")
  let button = campy_form.wire_id("button-1")
  pet |> should.equal(campy_form.wire_id("pet-button"))
  let distinct = pet == feed
  distinct |> should.be_false
  let positive = button > 0
  positive |> should.be_true

  let assert [cat_cafe, ..] = project.campy().modules
  let ids = cat_cafe.form.controls |> list.map(campy_form.control_wire_id)
  list.all(ids, fn(id) { id > 0 }) |> should.be_true
  list.length(ids) |> should.equal(list.length(list.unique(ids)))
  campy_form.validate(cat_cafe.form) |> should.be_ok

  // The loop maps an event id back to the model control without the document.
  campy_form.find_control_by_wire_id(
    cat_cafe.form,
    campy_form.wire_id("pet-button"),
  )
  |> should.be_some
}

pub fn every_kind_round_trips_through_its_key_test() {
  let kinds = [
    campy_form.Label,
    campy_form.EditBox,
    campy_form.Memo,
    campy_form.Button,
    campy_form.CheckBox,
    campy_form.RadioButton,
    campy_form.ComboBox,
    campy_form.ListBox,
    campy_form.Slider,
    campy_form.Progress,
    campy_form.Panel,
    campy_form.GroupBox,
    campy_form.Picture,
    campy_form.Menu,
    campy_form.CodeEditor,
    campy_form.Console,
  ]
  kinds
  |> list.map(campy_form.kind_key)
  |> should.equal([
    "label", "edit", "memo", "button", "checkbox", "radio", "combo", "list",
    "slider", "progress", "panel", "group", "picture", "menu", "code_editor",
    "console",
  ])
  list.each(kinds, fn(kind) {
    campy_form.kind_from_key(campy_form.kind_key(kind))
    |> should.equal(Some(kind))
  })
  campy_form.kind_from_key("nope") |> should.equal(None)
}

// --- Helpers ---------------------------------------------------------------

fn control(
  id: String,
  name: String,
  kind: campy_form.Kind,
  x: Int,
  y: Int,
  width: Int,
  height: Int,
  text: String,
) -> campy_form.Control {
  control_with_props(id, name, kind, x, y, width, height, text, [])
}

fn control_with_props(
  id: String,
  name: String,
  kind: campy_form.Kind,
  x: Int,
  y: Int,
  width: Int,
  height: Int,
  text: String,
  props: List(#(String, String)),
) -> campy_form.Control {
  campy_form.Control(
    id,
    name,
    kind,
    x,
    y,
    width,
    height,
    text,
    True,
    True,
    props,
  )
}

fn single_form(controls: List(campy_form.Control)) -> campy_form.Form {
  campy_form.Form(
    "campy.form",
    "Single",
    400,
    300,
    campy_form.Free,
    controls,
    [],
    [],
    [],
    [],
    [],
    [],
  )
}

fn picture_form() -> campy_form.Form {
  single_form([
    control(
      "pic-1",
      "pic1",
      campy_form.Picture,
      20,
      20,
      200,
      150,
      "assets/cat.png",
    ),
  ])
}

// A stable, readable rendering of the document: one line per node, children
// indented one level. Compared against the checked-in fixture.
fn describe(controls: List(ControlDesc)) -> String {
  controls |> describe_at(0) |> string.join("\n")
}

fn describe_at(controls: List(ControlDesc), depth: Int) -> List(String) {
  list.flat_map(controls, fn(desc) {
    [describe_control(desc, depth), ..describe_at(desc.children, depth + 1)]
  })
}

fn describe_control(desc: ControlDesc, depth: Int) -> String {
  string.repeat("  ", depth)
  <> desc.kind
  <> " id="
  <> int.to_string(desc.id)
  <> " text="
  <> escaped(desc.text)
  <> " xy="
  <> int.to_string(desc.x)
  <> ","
  <> int.to_string(desc.y)
  <> " wh="
  <> int.to_string(desc.w)
  <> "x"
  <> int.to_string(desc.h)
  <> " enabled="
  <> bool_text(desc.enabled)
  <> " visible="
  <> bool_text(desc.visible)
  <> " props="
  <> props_text(desc.props)
}

fn props_text(props: List(#(String, WireValue))) -> String {
  case props {
    [] -> "-"
    _ ->
      props
      |> list.map(fn(entry) { entry.0 <> ":" <> value_text(entry.1) })
      |> string.join(" ")
  }
}

fn value_text(value: WireValue) -> String {
  case value {
    WireText(text) -> escaped(text)
    WireBool(flag) -> bool_text(flag)
    WireInt(int) -> int.to_string(int)
    WireFloat(float) -> float.to_string(float)
    WireImage(path) -> "image(" <> escaped(path) <> ")"
    WireList(items) ->
      "[" <> string.join(list.map(items, value_text), ", ") <> "]"
    WireStruct(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(field) { field.0 <> "=" <> value_text(field.1) }),
        ", ",
      )
      <> "}"
  }
}

fn escaped(text: String) -> String {
  let body =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> body <> "\""
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

@external(erlang, "campy_form_fixture_ffi", "read_file")
fn read_fixture(path: String) -> Result(String, String)

@external(erlang, "campy_form_fixture_ffi", "write_file")
fn write_fixture(path: String, contents: String) -> Nil

@external(erlang, "campy_form_fixture_ffi", "update_fixture")
fn update_fixture() -> Bool
