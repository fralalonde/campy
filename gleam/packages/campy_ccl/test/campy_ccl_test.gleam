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
  list.length(keys) |> should.equal(13)
  list.length(keys) |> should.equal(list.length(list.unique(keys)))
}

pub fn events_and_containers_follow_the_catalog_test() {
  let assert Some(button) = campy_ccl.find("button")
  button.accepts_children |> should.be_false
  let assert Some(campy_ccl.Event("clicked", _)) = button.event

  let assert Some(panel) = campy_ccl.find("panel")
  panel.accepts_children |> should.be_true
  panel.event |> should.equal(None)

  let assert Some(group) = campy_ccl.find("group")
  group.accepts_children |> should.be_true
}

pub fn palette_labels_include_the_icon_test() {
  let assert Some(label) = campy_ccl.find("label")
  campy_ccl.palette_label(label) |> should.equal("T  Label")
}
