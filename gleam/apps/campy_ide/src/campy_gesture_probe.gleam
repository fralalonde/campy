//// Native gesture probe: drives the protocol-v2 surface with synthetic pointer
//// input through the headless ui-testing driver and verifies the input path
//// the IDE loop consumes:
////
//// 1. The designer `surface` forwards raw pointer phases as
////    `pointer:<canvas>:down/move/up` with window CSS-pixel payloads.
//// 2. A campy button emits `control:<wire id>:clicked` (the palette/shell path).
////
//// The gesture *semantics* (marquee, drag-move, select-on-release) live in
//// `campy_ide/state` now and are covered by its unit tests; this probe proves
//// the renderer half of the contract. Run with the ui-testing NIF feature:
//// `just probe-gestures`.

import campy_bridge.{type ControlDesc}
import campy_form/project
import campy_ide/ide_ui
import campy_ide/shell
import campy_ide/state

@external(erlang, "campy_gesture_probe_ffi", "run")
fn run(
  title: String,
  width: Int,
  height: Int,
  theme: String,
  controls: List(ControlDesc),
  canvas_id: Int,
  button_id: Int,
  button_x: Float,
  button_y: Float,
) -> Nil

pub fn main() {
  let model = state.initial(project.campy())
  let view = ide_ui.snapshot(model)
  // The console pane is free layout, so the Clear button sits at
  // canvas-independent absolute coordinates: pane (191,663) + (700,2).
  run(
    shell.window_title(view.title),
    shell.window_width,
    shell.window_height,
    view.theme,
    shell.desc(view),
    shell.section_id("canvas"),
    shell.section_id("console-clear"),
    921.0,
    678.0,
  )
}
