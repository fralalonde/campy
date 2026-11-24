//// Native gesture probe: drives the real designer shell with synthetic
//// pointer input (press/move/release) through the ui-testing NIF and
//// verifies the hybrid drag contract:
//// 1. Dragging from an unselected control draws the marquee (frame-apply)
////    and never emits a move or drop-candidate cursor.
//// 2. Dragging from a selected control arms the move (drag-over + move-x).
//// 3. Pressing and releasing without movement selects on button-up.
//// Run with the ui-testing NIF feature: `gleam run -m campy_gesture_probe`.

import campy_bridge
import campy_form/project
import campy_ide/ide_ui
import campy_ide/state
import gleam/list

pub type SurfaceSpec {
  SurfaceSpec(id: String, px: Int, py: Int)
}

@external(erlang, "campy_gesture_probe_ffi", "run")
fn run(
  source: String,
  modules: List(campy_bridge.WireValue),
  tabs: List(campy_bridge.WireValue),
  controls: List(campy_bridge.WireValue),
  code: List(campy_bridge.WireValue),
  selected: List(campy_bridge.WireValue),
  cleared: List(campy_bridge.WireValue),
  surfaces: List(SurfaceSpec),
  pane_x: Int,
  pane_y: Int,
  window_x: Int,
  window_y: Int,
) -> Nil

fn free_surface(control: ide_ui.ControlItem) -> Bool {
  !control.arranged && control.visible && control.w >= 60 && control.h >= 30
}

// Controls are flat siblings in z-order (later control-items render on top),
// so the press point must avoid every other control. Try the centre, then
// the four corners inset by 10px.
fn press_point(
  target: ide_ui.ControlItem,
  others: List(ide_ui.ControlItem),
) -> #(Int, Int) {
  let candidates = [
    #(target.x + target.w / 2, target.y + target.h / 2),
    #(target.x + 10, target.y + 10),
    #(target.x + target.w - 10, target.y + target.h - 10),
    #(target.x + target.w - 10, target.y + 10),
    #(target.x + 10, target.y + target.h - 10),
  ]
  let assert [point, ..] =
    list.filter(candidates, fn(point) {
      let #(px, py) = point
      !list.any(others, fn(other) {
        other.id != target.id
        && other.visible
        && px > other.x + 2
        && px < other.x + other.w - 2
        && py > other.y + 2
        && py < other.y + other.h - 2
      })
    })
  point
}

pub fn main() {
  let model = state.initial(project.campy())
  // Z2.2 compile shim: the IDE shell is a `ControlDesc` document now, so there
  // is no Slint source to hand the ui-testing FFI. Z2.3 rewrites this probe for
  // pointer-only surfaces; until then it still builds and starts.
  let source = ""
  let snapshot = ide_ui.snapshot(model)
  // A large, unselected, free-layout control to start every gesture on.
  let assert [target, ..] = list.filter(snapshot.controls, free_surface)
  let selected_model = state.select(model, target.id)
  let cleared_model = state.select(selected_model, "")
  let #(window_x, window_y) = state.window_position(model)
  // Canvas pane origin inside the IDE window, from shell.gleam's fixed
  // chrome: menu bar 46px + tab strip 32px, navigator 190px + 1px divider.
  let pane_x = 191
  let pane_y = 78
  let #(px, py) = press_point(target, snapshot.controls)
  run(
    source,
    ide_ui.modules_wire(snapshot.modules),
    ide_ui.tabs_wire(snapshot.tabs),
    ide_ui.controls_wire(snapshot.controls),
    ide_ui.code_wire(snapshot.code),
    ide_ui.controls_wire(ide_ui.snapshot(selected_model).controls),
    ide_ui.controls_wire(ide_ui.snapshot(cleared_model).controls),
    [SurfaceSpec(target.id, px, py)],
    pane_x,
    pane_y,
    window_x,
    window_y,
  )
}
