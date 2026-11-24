// Native rendering/input/lifecycle smoke over protocol v2.
//
// Loads the Cat Café form's `ControlDesc` document, clicks a designed button
// through the headless input driver, reads a label back, reloads the document
// at a new generation, and exercises the session lifecycle (generation guard,
// ownership, close). `just smoke-native` wraps this; Z4.1 adds the scene-dump
// golden assertions.

import campy_bridge.{type ControlDesc}
import campy_form
import campy_form/live_preview
import campy_form/project
import gleam/int
import gleam/option.{Some}

@external(erlang, "campy_native_smoke_ffi", "run")
fn run(
  title: String,
  width: Int,
  height: Int,
  theme: String,
  controls: List(ControlDesc),
  click_id: Int,
  click_x: Float,
  click_y: Float,
  label_id: Int,
  label_text: String,
) -> Nil

pub fn main() {
  let assert Some(cat) = project.find_module(project.campy(), "cat-cafe")
  let assert Some(button) = campy_form.find_control(cat.form, "pet-button")
  let assert Some(label) = campy_form.find_control(cat.form, "label-1")
  let #(x, y, w, h) = campy_form.bounds(cat.form, button)
  run(
    cat.form.title,
    cat.form.width,
    cat.form.height,
    "dark",
    live_preview.to_controls(cat.form),
    campy_form.control_wire_id(button),
    int.to_float(x + w / 2),
    int.to_float(y + h / 2),
    campy_form.control_wire_id(label),
    label.text,
  )
}
