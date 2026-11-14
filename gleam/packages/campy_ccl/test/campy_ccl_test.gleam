import campy_ccl
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn catalog_has_unique_keys_test() {
  let keys = list.map(campy_ccl.all(), fn(component) { component.key })
  list.length(keys) |> should.equal(14)
  list.length(keys) |> should.equal(list.length(list.unique(keys)))
}

pub fn events_follow_the_catalog_test() {
  let assert Some(button) = campy_ccl.find("button")
  button.accepts_children |> should.be_false
  button.events |> should.equal([campy_ccl.Event("clicked", "OnClicked")])

  let assert Some(panel) = campy_ccl.find("panel")
  panel.accepts_children |> should.be_true
  panel.events |> should.equal([])

  let assert Some(group) = campy_ccl.find("group")
  group.accepts_children |> should.be_true
}

pub fn property_schemas_are_slint_shaped_test() {
  // Edit follows Slint's LineEdit: placeholder-text + read-only, with
  // accepted/edited callbacks.
  let assert Some(edit) = campy_ccl.find("edit")
  edit.events
  |> should.equal([
    campy_ccl.Event("accepted", "OnAccepted"),
    campy_ccl.Event("edited", "OnEdited"),
  ])
  campy_ccl.prop_default("edit", "placeholder-text")
  |> should.equal("")
  campy_ccl.prop_default("edit", "read-only") |> should.equal("false")
  campy_ccl.prop_label("edit", "placeholder-text")
  |> should.equal("Placeholder")

  // Slider follows Slint's Slider: minimum/maximum properties and the
  // changed/moved/released callbacks.
  let assert Some(slider) = campy_ccl.find("slider")
  campy_ccl.prop_default("slider", "minimum") |> should.equal("0")
  campy_ccl.prop_default("slider", "maximum") |> should.equal("100")
  list.length(slider.events) |> should.equal(2)

  // Checkbox carries Slint's checked property and toggled callback.
  let assert Some(checkbox) = campy_ccl.find("checkbox")
  campy_ccl.prop_default("checkbox", "checked") |> should.equal("false")
  checkbox.events
  |> should.equal([campy_ccl.Event("toggled", "OnToggle")])
}

pub fn unknown_keys_degrade_gracefully_test() {
  campy_ccl.properties("nope") |> should.equal([])
  campy_ccl.events("nope") |> should.equal([])
  campy_ccl.prop_default("nope", "checked") |> should.equal("")
  campy_ccl.prop_label("edit", "nope") |> should.equal("nope")
  campy_ccl.event_label("edit", "nope") |> should.equal("")
  campy_ccl.find("nope") |> should.equal(None)
}
