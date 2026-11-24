import campy_ccl
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// The wire kind table from `docs/PHASE2.md` §1.4, in catalog order. `surface`
// is IDE-internal and never in the palette.
const kind_keys = [
  "label",
  "edit",
  "memo",
  "button",
  "menu",
  "checkbox",
  "radio",
  "combo",
  "list",
  "slider",
  "progress",
  "panel",
  "group",
  "picture",
  "code_editor",
  "console",
]

fn keys() -> List(String) {
  list.map(campy_ccl.all(), fn(component) { component.key })
}

fn events_of(key: String) -> List(String) {
  campy_ccl.events(key) |> list.map(fn(event) { event.key })
}

fn prop_keys(key: String) -> List(String) {
  campy_ccl.properties(key) |> list.map(fn(property) { property.key })
}

pub fn catalog_has_unique_keys_test() {
  let keys = keys()
  keys |> should.equal(kind_keys)
  list.length(keys) |> should.equal(16)
  list.length(keys) |> should.equal(list.length(list.unique(keys)))

  // A key addresses exactly one entry, and palette labels are unique too.
  list.each(keys, fn(key) {
    let assert Some(component) = campy_ccl.find(key)
    component.key |> should.equal(key)
  })
  let labels = list.map(campy_ccl.all(), campy_ccl.palette_label)
  list.length(labels) |> should.equal(list.length(list.unique(labels)))
}

pub fn catalog_is_the_zgui_kind_table_test() {
  // Every entry declares a palette-ready label, icon, and known category.
  list.each(campy_ccl.all(), fn(component) {
    component.label |> should.not_equal("")
    component.icon |> should.not_equal("")
    list.contains(campy_ccl.categories(), component.category)
    |> should.be_true
  })

  // Categories partition the catalog: every category yields its members and
  // together they cover every component exactly once.
  let grouped =
    campy_ccl.categories()
    |> list.flat_map(campy_ccl.components_in)
    |> list.map(fn(component) { component.key })
  list.length(grouped) |> should.equal(list.length(kind_keys))
  list.length(grouped) |> should.equal(list.length(list.unique(grouped)))
  list.each(kind_keys, fn(key) { list.contains(grouped, key) |> should.be_true })
}

pub fn new_kinds_are_common_with_default_sizes_test() {
  let assert Some(editor) = campy_ccl.find("code_editor")
  editor.category |> should.equal("Common")
  editor.default_width |> should.equal(400)
  editor.default_height |> should.equal(300)

  let assert Some(console) = campy_ccl.find("console")
  console.category |> should.equal("Common")
  console.default_width |> should.equal(480)
  console.default_height |> should.equal(240)
}

pub fn surface_stays_out_of_the_palette_test() {
  campy_ccl.find("surface") |> should.equal(None)
  campy_ccl.find("menu-list") |> should.equal(None)
}

pub fn universal_text_property_test() {
  // `text` is the CCL-universal property: first in every schema, defaulting to
  // the component's default text.
  list.each(campy_ccl.all(), fn(component) {
    case component.properties {
      [first, ..] -> first.key |> should.equal(campy_ccl.text_key)
      [] -> should.fail()
    }
    campy_ccl.prop_default(component.key, campy_ccl.text_key)
    |> should.equal(component.default_text)
  })
}

pub fn required_events_per_kind_test() {
  [
    #("label", []),
    #("edit", ["accepted", "edited"]),
    #("memo", ["edited"]),
    #("button", ["clicked"]),
    #("menu", ["clicked", "selected"]),
    #("checkbox", ["toggled"]),
    #("radio", ["toggled"]),
    #("combo", ["selected"]),
    #("list", ["selected"]),
    #("slider", ["changed"]),
    #("progress", ["changed"]),
    #("panel", []),
    #("group", []),
    #("picture", []),
    #("code_editor", ["edited"]),
    #("console", []),
  ]
  |> list.each(fn(entry) {
    let #(key, expected) = entry
    events_of(key) |> should.equal(expected)
    list.length(campy_ccl.events(key))
    |> should.equal(list.length(list.unique(events_of(key))))
  })

  // Every declared event resolves to a handler-facing label.
  list.each(campy_ccl.all(), fn(component) {
    list.each(component.events, fn(event) {
      campy_ccl.event_label(component.key, event.key)
      |> should.equal(event.label)
    })
  })
}

pub fn notable_props_match_the_wire_table_test() {
  [
    #("label", ["text"]),
    #("edit", ["text", "placeholder", "read-only"]),
    #("memo", ["text", "read-only"]),
    #("button", ["text", "variant"]),
    #("menu", ["text", "model"]),
    #("checkbox", ["text", "checked"]),
    #("radio", ["text", "checked", "group"]),
    #("combo", ["text", "model", "current-index"]),
    #("list", ["text", "model"]),
    #("slider", ["text", "minimum", "maximum", "value"]),
    #("progress", ["text", "value", "maximum"]),
    #("panel", ["text", "layout", "border"]),
    #("group", ["text", "layout", "border"]),
    #("picture", ["text", "source", "fit", "transparency"]),
    #("code_editor", ["text", "language", "read-only", "line-numbers"]),
    #("console", ["text"]),
  ]
  |> list.each(fn(entry) {
    let #(key, expected) = entry
    prop_keys(key) |> should.equal(expected)
    list.length(prop_keys(key))
    |> should.equal(list.length(list.unique(prop_keys(key))))
  })
}

pub fn prop_defaults_and_labels_test() {
  // Edit follows zgui's Input: `placeholder` (the Slint `placeholder-text`
  // name is gone) and `read-only`, with accepted/edited events.
  campy_ccl.prop_default("edit", "placeholder") |> should.equal("")
  campy_ccl.prop_default("edit", "placeholder-text") |> should.equal("")
  campy_ccl.prop_default("edit", "read-only") |> should.equal("false")
  campy_ccl.prop_label("edit", "placeholder") |> should.equal("Placeholder")

  // Button's variant defaults to the solid style.
  campy_ccl.prop_default("button", "variant") |> should.equal("solid")

  // Slider and progress read minimum/maximum/value as numbers.
  campy_ccl.prop_default("slider", "minimum") |> should.equal("0")
  campy_ccl.prop_default("slider", "maximum") |> should.equal("100")
  campy_ccl.prop_default("slider", "value") |> should.equal("50")
  campy_ccl.prop_default("progress", "value") |> should.equal("60")
  campy_ccl.prop_default("progress", "maximum") |> should.equal("100")

  // Checkbox and radio carry the checked state; radio adds a group.
  campy_ccl.prop_default("checkbox", "checked") |> should.equal("false")
  campy_ccl.prop_default("radio", "checked") |> should.equal("false")
  campy_ccl.prop_default("radio", "group") |> should.equal("")

  // Combo keeps a current-index.
  campy_ccl.prop_default("combo", "current-index") |> should.equal("0")

  // Containers declare their layout and border props.
  campy_ccl.prop_default("panel", "layout") |> should.equal("free")
  campy_ccl.prop_default("group", "layout") |> should.equal("free")
  campy_ccl.prop_default("panel", "border") |> should.equal("0")

  // Picture keeps source and transparency, and gains fit.
  campy_ccl.prop_default("picture", "source") |> should.equal("")
  campy_ccl.prop_default("picture", "fit") |> should.equal("contain")
  campy_ccl.prop_default("picture", "transparency") |> should.equal("0")

  // code_editor maps to zgui-editor with the Gleam grammar.
  campy_ccl.prop_default("code_editor", "language") |> should.equal("gleam")
  campy_ccl.prop_default("code_editor", "line-numbers") |> should.equal("true")
  campy_ccl.prop_default("code_editor", "read-only") |> should.equal("false")
}

pub fn containers_accept_children_test() {
  list.each(campy_ccl.all(), fn(component) {
    let expected = component.key == "panel" || component.key == "group"
    component.accepts_children |> should.equal(expected)
  })
}

pub fn unknown_keys_degrade_gracefully_test() {
  campy_ccl.properties("nope") |> should.equal([])
  campy_ccl.events("nope") |> should.equal([])
  campy_ccl.prop_default("nope", "checked") |> should.equal("")
  campy_ccl.prop_label("edit", "nope") |> should.equal("nope")
  campy_ccl.event_label("edit", "nope") |> should.equal("")
  campy_ccl.find("nope") |> should.equal(None)
  campy_ccl.components_in("nope") |> should.equal([])
}
