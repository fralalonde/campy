//// Campy IDE shell on wx.
////
//// Loads a project directory, renders the shell view, and forwards wx events
//// into `campy_ide_model`. Document logic lives in the model; this module
//// builds the view tree, applies its diffs, and fills data-driven panes.
////
//// Run: `CAMPY_PROJECT=examples/demo gleam run` from this directory.
//// Smoke: `CAMPY_WX_SMOKE=1` runs mount/switch/select/close without a loop.

import campy_catalog
import campy_design
import campy_ide_model as model
import campy_project
import campy_view.{type Node, VBool, VInt, VList, VMap, VText}
import campy_view/diff
import campy_wx
import campy_wx/plan
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn main() {
  let dir = case campy_wx.getenv("CAMPY_PROJECT") {
    "" -> "../../../examples/demo"
    dir -> dir
  }

  case campy_project.load(dir) {
    Error(error) -> io.println("[ide] cannot load " <> dir <> ": " <> error)
    Ok(project) ->
      case campy_wx.getenv("CAMPY_WX_SMOKE") {
        "1" -> smoke(project, dir)
        _ -> interactive(project, dir)
      }
  }
}

fn interactive(project: campy_project.Project, dir: String) {
  let shell = campy_wx.start("Campy", 980, 760)
  let state = model.new(project) |> model.update(model.Log("Loaded " <> dir))
  let current_view = view(state)

  let assert Ok(shell) = campy_wx.mount(shell, current_view)
  refresh(shell, None, state)
  loop(shell, state, current_view, dir, NoDrag)
}

fn smoke(project: campy_project.Project, dir: String) {
  let shell = campy_wx.start("Campy smoke", 980, 760)
  let started = campy_wx.now_ms()
  let state = model.new(project) |> model.update(model.Log("Loaded " <> dir))
  let current_view = view(state)

  let assert Ok(shell) = campy_wx.mount(shell, current_view)
  io.println(
    "[ide] mount " <> int.to_string(campy_wx.now_ms() - started) <> "ms",
  )
  refresh(shell, None, state)

  let previous = state
  let state = case project.modules {
    [_, second, ..] -> model.update(state, model.OpenModule(second.slug))
    _ -> state
  }
  let shell = rebind(shell, current_view, view(state))
  let state = select_first_control(state)
  refresh(shell, Some(previous), state)

  io.println(
    "[ide] active="
    <> active_slug(state)
    <> " selection="
    <> int.to_string(list.length(state.selection)),
  )
  io.println("[ide] smoke ok")
  campy_wx.close(shell)
}

fn rebind(shell: campy_wx.Shell, previous: Node, next: Node) -> campy_wx.Shell {
  case campy_wx.apply(shell, diff.diff(previous, next)) {
    Ok(shell) -> shell
    Error(error) -> {
      io.println("[ide] view error: " <> error)
      shell
    }
  }
}

fn select_first_control(state: model.State) -> model.State {
  case model.active_module(state) {
    Ok(module) ->
      case module.form.view.children {
        [first, ..] -> model.select_controls(state, [first.id])
        [] -> state
      }
    Error(_) -> state
  }
}

fn loop(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
) {
  case campy_wx.next(shell, 100) {
    campy_wx.Closed -> {
      campy_wx.close(shell)
      io.println("[ide] closed")
    }
    campy_wx.Paint(id) -> {
      campy_wx.paint(shell, id)
      loop(shell, state, current, dir, drag)
    }
    campy_wx.MouseHandle(role, kind, x, y) ->
      handle_mouse(shell, state, current, dir, drag, role, kind, x, y)
    campy_wx.Mouse(id, kind, x, y, control) ->
      handle_design_mouse(
        shell,
        state,
        current,
        dir,
        drag,
        id,
        kind,
        x,
        y,
        control,
      )
    campy_wx.Event(id, key, value) ->
      case id {
        "menu-quit" -> {
          campy_wx.close(shell)
          io.println("[ide] quit")
        }
        _ -> {
          let previous = state
          let state = handle(state, dir, id, key, value)
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
      }
    campy_wx.Message(_message) -> loop(shell, state, current, dir, drag)
    campy_wx.Idle -> loop(shell, state, current, dir, drag)
  }
}

fn handle_mouse(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  role: Int,
  kind: String,
  x: Int,
  y: Int,
) {
  case kind {
    "left_down" -> {
      let next_drag = start_drag(state, role, x, y)
      case next_drag {
        NoDrag -> loop(shell, state, current, dir, NoDrag)
        _ -> {
          campy_wx.capture_handle(shell, role)
          loop(shell, state, current, dir, next_drag)
        }
      }
    }
    "motion" -> {
      case drag_previews(drag, x, y) {
        [] -> Nil
        previews ->
          list.each(previews, fn(preview) {
            let #(id, rect) = preview
            let #(rx, ry, rw, rh) = preview_in_parent(state, id, rect)
            campy_wx.preview_rect(shell, id, rx, ry, rw, rh)
          })
      }
      loop(shell, state, current, dir, drag)
    }
    "left_up" -> {
      campy_wx.release_handle(shell, role)
      case drag_previews(drag, x, y) {
        [] -> loop(shell, state, current, dir, NoDrag)
        previews -> {
          let previous = state
          let reparent = move_reparent(state, drag, previews)
          let state =
            model.update(
              state,
              model.CommitGeometry(
                list.map(previews, fn(preview) {
                  let #(id, #(rx, ry, rw, rh)) = preview
                  #(id, campy_design.Rect(x: rx, y: ry, w: rw, h: rh))
                }),
                reparent,
              ),
            )
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
      }
    }
    _ -> loop(shell, state, current, dir, drag)
  }
}

fn handle_design_mouse(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  id: String,
  kind: String,
  x: Int,
  y: Int,
  control: Bool,
) {
  case kind {
    "left_down" ->
      case state.armed {
        Some(kind) ->
          start_placement(shell, state, current, dir, kind, id, x, y)
        None ->
          case id {
            "canvas" ->
              case hit_target(state, x, y) {
                Some(target) ->
                  case control {
                    True -> {
                      let previous = state
                      let state = toggle_selection(state, target)
                      refresh(shell, Some(previous), state)
                      loop(shell, state, current, dir, NoDrag)
                    }
                    False -> {
                      let previous = state
                      let state = model.select_controls(state, [target])
                      refresh(shell, Some(previous), state)
                      loop(shell, state, current, dir, NoDrag)
                    }
                  }
                None -> {
                  let state = model.select_controls(state, [])
                  campy_wx.show_selection(shell, None, False)
                  campy_wx.capture_canvas(shell)
                  let previous = state
                  refresh(shell, Some(previous), state)
                  loop(shell, state, current, dir, MarqueeDrag(x, y))
                }
              }
            _ -> {
              let previous = state
              let state = case control {
                True -> toggle_widget_selection(state, id)
                False -> select_control(state, id, "select")
              }
              refresh(shell, Some(previous), state)
              loop(shell, state, current, dir, NoDrag)
            }
          }
      }
    "motion" ->
      case drag {
        PlacementDrag(_kind, start_x, start_y) -> {
          let #(px, py) = event_absolute(state, id, x, y)
          campy_wx.show_marquee(
            shell,
            Some(normalize_rect(start_x, start_y, px, py)),
          )
          loop(shell, state, current, dir, drag)
        }
        MarqueeDrag(start_x, start_y) -> {
          campy_wx.show_marquee(
            shell,
            Some(normalize_rect(start_x, start_y, x, y)),
          )
          loop(shell, state, current, dir, drag)
        }
        _ -> loop(shell, state, current, dir, drag)
      }
    "left_up" ->
      case drag {
        PlacementDrag(kind, start_x, start_y) -> {
          let #(px, py) = event_absolute(state, id, x, y)
          let rect = normalize_rect(start_x, start_y, px, py)
          campy_wx.release_canvas(shell)
          campy_wx.show_marquee(shell, None)
          let previous = state
          let #(width, height) = case rect.2 < 6 || rect.3 < 6 {
            True -> #(0, 0)
            False -> #(rect.2, rect.3)
          }
          let state =
            model.update(
              state,
              model.PlaceWidget(kind, rect.0, rect.1, width, height),
            )
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
        MarqueeDrag(start_x, start_y) -> {
          let rect = normalize_rect(start_x, start_y, x, y)
          campy_wx.release_canvas(shell)
          campy_wx.show_marquee(shell, None)
          let state = case model.active_module(state) {
            Error(_) -> state
            Ok(module) -> {
              let layout = campy_design.resolve(module.form.view)
              model.select_controls(
                state,
                campy_design.intersecting(
                  layout,
                  campy_design.Rect(x: rect.0, y: rect.1, w: rect.2, h: rect.3),
                ),
              )
            }
          }
          let previous = state
          refresh(shell, Some(previous), state)
          loop(shell, state, current, dir, NoDrag)
        }
        _ -> loop(shell, state, current, dir, drag)
      }
    _ -> loop(shell, state, current, dir, drag)
  }
}

fn normalize_rect(sx: Int, sy: Int, x: Int, y: Int) -> #(Int, Int, Int, Int) {
  #(
    int.min(sx, x),
    int.min(sy, y),
    int.max(sx, x) - int.min(sx, x) + 1,
    int.max(sy, y) - int.min(sy, y) + 1,
  )
}

fn hit_target(state: model.State, x: Int, y: Int) -> Option(String) {
  case model.active_module(state) {
    Error(_) -> None
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      case campy_design.at(layout, x, y) {
        Some(placed) ->
          case placed.id == layout.root {
            True -> None
            False -> Some(placed.id)
          }
        None -> None
      }
    }
  }
}

fn start_placement(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  kind: String,
  id: String,
  x: Int,
  y: Int,
) {
  case id {
    "canvas" -> {
      campy_wx.capture_canvas(shell)
      loop(shell, state, current, dir, PlacementDrag(kind, x, y))
    }
    _ -> {
      let #(px, py) = event_absolute(state, id, x, y)
      let previous = state
      let state = model.update(state, model.PlaceWidget(kind, px, py, 0, 0))
      let next = view(state)
      let shell = rebind(shell, current, next)
      refresh(shell, Some(previous), state)
      loop(shell, state, next, dir, NoDrag)
    }
  }
}

/// Convert a click on any design widget into canvas coordinates. Labels often
/// do not emit mouse events on GTK, but buttons, panels, and text fields do.
fn event_absolute(
  state: model.State,
  id: String,
  x: Int,
  y: Int,
) -> #(Int, Int) {
  case id {
    "canvas" -> #(x, y)
    _ ->
      case model.active_module(state) {
        Error(_) -> #(x, y)
        Ok(module) ->
          case campy_design.absolute(module.form.view, id) {
            Some(rect) -> #(rect.x + x, rect.y + y)
            None -> #(x, y)
          }
      }
  }
}

/// Native children are positioned relative to their parent, while drags are
/// tracked in canvas coordinates.
fn preview_in_parent(
  state: model.State,
  id: String,
  rect: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int) {
  let #(x, y, w, h) = rect
  let #(ox, oy) = case model.active_module(state) {
    Error(_) -> #(0, 0)
    Ok(module) -> campy_design.parent_origin(module.form.view, id)
  }
  #(x - ox, y - oy, w, h)
}

/// A single-control move that ends over another container reparents it. Group
/// moves stay together in their current parent.
fn move_reparent(
  state: model.State,
  drag: Drag,
  previews: List(#(String, #(Int, Int, Int, Int))),
) -> Option(#(String, String)) {
  case drag {
    MoveDrag([#(id, _)], _, _) ->
      case list.find(previews, fn(preview) { preview.0 == id }) {
        Error(Nil) -> None
        Ok(#(_, #(x, y, w, h))) ->
          case model.active_module(state) {
            Error(_) -> None
            Ok(module) -> {
              let layout = campy_design.resolve(module.form.view)
              let current = campy_design.parent_of(module.form.view, id)
              let target =
                campy_design.container_for_drop(
                  module.form.view,
                  layout,
                  x + w / 2,
                  y + h / 2,
                  Some(id),
                )
              case target {
                None -> None
                Some(placed) ->
                  case current {
                    Some(parent) if parent == placed.id -> None
                    _ -> Some(#(id, placed.id))
                  }
              }
            }
          }
      }
    _ -> None
  }
}

fn start_drag(state: model.State, role: Int, x: Int, y: Int) -> Drag {
  case role == 8 {
    True ->
      case selection_items(state) {
        [] -> NoDrag
        items -> MoveDrag(items, x, y)
      }
    False ->
      case state.selection {
        [id] ->
          case selection_items(state) {
            [#(_, rect), ..] -> ResizeDrag(id, role, x, y, rect)
            [] -> NoDrag
          }
        _ -> NoDrag
      }
  }
}

fn selection_items(
  state: model.State,
) -> List(#(String, #(Int, Int, Int, Int))) {
  case model.active_module(state) {
    Error(_) -> []
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      // Moving a container already moves its descendants; preview and commit
      // only the top-level selected controls.
      let ids =
        list.filter(state.selection, fn(id) {
          !list.any(state.selection, fn(other) {
            other != id && campy_design.is_within(module.form.view, other, id)
          })
        })
      list.filter_map(ids, fn(id) {
        case campy_design.placed(layout, id) {
          Some(placed) ->
            Ok(#(
              id,
              #(placed.rect.x, placed.rect.y, placed.rect.w, placed.rect.h),
            ))
          None -> Error(Nil)
        }
      })
    }
  }
}

fn drag_previews(
  drag: Drag,
  x: Int,
  y: Int,
) -> List(#(String, #(Int, Int, Int, Int))) {
  case drag {
    NoDrag -> []
    PlacementDrag(_, _, _) -> []
    MarqueeDrag(_, _) -> []
    MoveDrag(items, start_x, start_y) ->
      list.map(items, fn(item) {
        let #(id, #(rx, ry, rw, rh)) = item
        #(id, #(rx + x - start_x, ry + y - start_y, rw, rh))
      })
    ResizeDrag(id, role, start_x, start_y, #(rx, ry, rw, rh)) -> {
      let dx = x - start_x
      let dy = y - start_y
      let left = case role {
        0 | 6 | 7 -> rx + dx
        _ -> rx
      }
      let top = case role {
        0 | 1 | 2 -> ry + dy
        _ -> ry
      }
      let right = case role {
        2 | 3 | 4 -> rx + rw + dx
        _ -> rx + rw
      }
      let bottom = case role {
        4 | 5 | 6 -> ry + rh + dy
        _ -> ry + rh
      }
      let #(left, right) = case right - left < campy_design.min_size {
        True ->
          case role {
            0 | 6 | 7 -> #(right - campy_design.min_size, right)
            _ -> #(left, left + campy_design.min_size)
          }
        False -> #(left, right)
      }
      let #(top, bottom) = case bottom - top < campy_design.min_size {
        True ->
          case role {
            0 | 1 | 2 -> #(bottom - campy_design.min_size, bottom)
            _ -> #(top, top + campy_design.min_size)
          }
        False -> #(top, bottom)
      }
      [#(id, #(left, top, right - left, bottom - top))]
    }
  }
}

type Drag {
  NoDrag
  PlacementDrag(kind: String, start_x: Int, start_y: Int)
  MarqueeDrag(start_x: Int, start_y: Int)
  MoveDrag(
    items: List(#(String, #(Int, Int, Int, Int))),
    start_x: Int,
    start_y: Int,
  )
  ResizeDrag(
    id: String,
    role: Int,
    start_x: Int,
    start_y: Int,
    rect: #(Int, Int, Int, Int),
  )
}

fn handle(
  state: model.State,
  dir: String,
  id: String,
  key: String,
  value: campy_view.Value,
) -> model.State {
  case id {
    "menu-save" | "tool-save" -> save(state, dir)
    "menu-undo" | "tool-undo" -> model.update(state, model.Undo)
    "menu-redo" | "tool-redo" -> model.update(state, model.Redo)
    "menu-toggle" | "tool-toggle" -> model.update(state, model.ToggleCodeView)
    "menu-copy" | "tool-copy" -> model.update(state, model.CopySelection)
    "menu-cut" | "tool-cut" -> model.update(state, model.CutSelection)
    "menu-paste" | "tool-paste" -> model.update(state, model.Paste)
    "menu-duplicate" | "tool-duplicate" ->
      model.update(state, model.DuplicateSelection)
    "menu-delete" | "tool-delete" -> model.update(state, model.DeleteSelection)
    "menu-front" -> model.update(state, model.BringToFront)
    "menu-back" -> model.update(state, model.SendToBack)
    "menu-cancel-place" -> model.update(state, model.Disarm)
    "palette" -> palette_selected(state, value)
    "inspector" -> inspector_changed(state, value)
    "events" -> event_selected(state, value)
    "modules" -> {
      case key, value {
        "select", VText(slug) -> tree_selected(state, slug)
        _, _ -> state
      }
    }
    _ -> select_or_log(state, id, key)
  }
}

fn palette_selected(
  state: model.State,
  value: campy_view.Value,
) -> model.State {
  case value {
    VInt(index) if index >= 0 ->
      case list.drop(campy_catalog.all(), index) {
        [widget, ..] -> model.update(state, model.Arm(widget.kind))
        [] -> state
      }
    _ -> state
  }
}

/// A grid edit arrives as row/col/text. Row 0 is the header; the inspector packs
/// two field/value pairs per row, so columns 1 and 3 are values. The field comes
/// from the label immediately left of the edited cell, never from a hard-coded
/// row index, so single and multi-selection layouts can differ.
fn inspector_changed(
  state: model.State,
  value: campy_view.Value,
) -> model.State {
  case value {
    VMap(fields) ->
      case
        field_int(fields, "row"),
        field_int(fields, "col"),
        field_text(fields, "text")
      {
        Some(row), Some(col), Some(text) ->
          case col {
            1 | 3 ->
              case list.drop(inspector_rows(state), row) {
                [row_values, ..] -> inspector_edit(state, row_values, col, text)
                [] -> state
              }
            _ -> state
          }
        _, _, _ -> state
      }
    _ -> state
  }
}

fn field_int(
  fields: List(#(String, campy_view.Value)),
  name: String,
) -> Option(Int) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, VInt(value))) -> Some(value)
    _ -> None
  }
}

fn field_text(
  fields: List(#(String, campy_view.Value)),
  name: String,
) -> Option(String) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, VText(value))) -> Some(value)
    _ -> None
  }
}

fn inspector_edit(
  state: model.State,
  row: List(String),
  col: Int,
  text: String,
) -> model.State {
  case list.drop(row, col - 1), state.selection {
    [label, _], [id] ->
      case label {
        "x" | "y" | "w" | "h" -> edit_geometry(state, id, label, text)
        "text" ->
          model.update(state, model.SetControlProp(id, "text", VText(text)))
        _ -> state
      }
    _, _ -> state
  }
}

fn edit_geometry(
  state: model.State,
  id: String,
  field: String,
  text: String,
) -> model.State {
  case int.parse(string.trim(text)), geometry_of(state, id) {
    Ok(value), Some(rect) -> {
      let next = case field {
        "x" -> campy_design.Rect(x: value, y: rect.y, w: rect.w, h: rect.h)
        "y" -> campy_design.Rect(x: rect.x, y: value, w: rect.w, h: rect.h)
        "w" -> campy_design.Rect(x: rect.x, y: rect.y, w: value, h: rect.h)
        _ -> campy_design.Rect(x: rect.x, y: rect.y, w: rect.w, h: value)
      }
      model.update(state, model.SetControlRect(id, next))
    }
    _, _ -> state
  }
}

fn geometry_of(state: model.State, id: String) -> Option(campy_design.Rect) {
  case model.active_module(state) {
    Ok(module) -> campy_design.absolute(module.form.view, id)
    Error(_) -> None
  }
}

fn event_selected(state: model.State, value: campy_view.Value) -> model.State {
  case value, state.selection {
    VInt(index), [id] ->
      case list.drop(event_items(state), index) {
        [event, ..] -> model.update(state, model.OpenHandler(id, event))
        [] -> state
      }
    _, _ -> state
  }
}

fn select_or_log(state: model.State, id: String, key: String) -> model.State {
  case id {
    "canvas" -> state
    _ -> select_control(state, id, key)
  }
}

fn toggle_widget_selection(state: model.State, id: String) -> model.State {
  case model.active_module(state) {
    Error(_) -> state
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        Some(_) -> toggle_selection(state, id)
        None -> state
      }
  }
}

fn select_control(state: model.State, id: String, key: String) -> model.State {
  case model.active_module(state) {
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        Some(_node) -> model.select_controls(state, [id])
        None -> model.update(state, model.Log("event " <> id <> "." <> key))
      }
    Error(_) -> model.update(state, model.Log("event " <> id <> "." <> key))
  }
}

/// Canvas clicks are hit-tested, not trusted to per-control events: GTK labels
/// do not emit mouse events, and bubbled clicks can otherwise clear a fresh
/// selection.
fn toggle_selection(state: model.State, id: String) -> model.State {
  case list.contains(state.selection, id) {
    True ->
      model.select_controls(
        state,
        list.filter(state.selection, fn(selected) { selected != id }),
      )
    False -> model.select_controls(state, list.append(state.selection, [id]))
  }
}

fn tree_selected(state: model.State, id: String) -> model.State {
  case campy_project.module(state.project, id) {
    Ok(_module) -> model.update(state, model.OpenModule(id))
    Error(_) -> state
  }
}

fn save(state: model.State, dir: String) -> model.State {
  case campy_project.save(state.project, dir) {
    Ok(Nil) -> model.update(state, model.Log("Saved " <> dir))
    Error(error) -> model.update(state, model.Log("Save failed: " <> error))
  }
}

fn refresh(
  shell: campy_wx.Shell,
  previous: Option(model.State),
  state: model.State,
) {
  case previous {
    None -> {
      campy_wx.set_tree(shell, "modules", tree_items(state))
      set_code(shell, state)
      set_console(shell, state)
      campy_wx.select_page(shell, "tabs", page_index(state))
    }
    Some(previous) -> {
      case previous.armed, state.armed {
        Some(_), None -> campy_wx.set_selection(shell, "palette", -1)
        _, _ -> Nil
      }
      // Handler edits and module changes must both refresh the Scintilla page;
      // otherwise a stub is committed but the old source stays visible.
      let handlers_changed = handlers_of(previous) != handlers_of(state)
      case previous.active == state.active && !handlers_changed {
        False -> {
          set_code(shell, state)
          case handlers_changed {
            True -> campy_wx.scroll_editor_to_end(shell, "code")
            False -> Nil
          }
        }
        True -> Nil
      }
      case previous.console == state.console {
        False -> set_console(shell, state)
        True -> Nil
      }
      case previous.code_view == state.code_view {
        False -> campy_wx.select_page(shell, "tabs", page_index(state))
        True -> Nil
      }
    }
  }

  let rows = inspector_rows(state)
  campy_wx.set_grid(shell, "inspector", rows)
  typed_grid_editors(shell, rows, list.length(state.selection) != 1)
  campy_wx.set_items(shell, "events", event_items(state))
  campy_wx.set_status(shell, status_text(state))
  campy_wx.show_selection(
    shell,
    selection_rect(state),
    list.length(state.selection) == 1,
  )
}

fn page_index(state: model.State) -> Int {
  case state.code_view {
    True -> 1
    False -> 0
  }
}

fn set_code(shell: campy_wx.Shell, state: model.State) {
  case model.active_module(state) {
    Ok(module) -> campy_wx.set_editor(shell, "code", module.handlers, False)
    Error(_) -> campy_wx.set_editor(shell, "code", "", True)
  }
}

fn handlers_of(state: model.State) -> String {
  case model.active_module(state) {
    Ok(module) -> module.handlers
    Error(_) -> ""
  }
}

/// x/y/w/h are integer cells; the rest stay text. Multi-selection is
/// read-only, so those cells reject edits instead of silently changing one of
/// several controls.
fn typed_grid_editors(
  shell: campy_wx.Shell,
  rows: List(List(String)),
  read_only: Bool,
) -> Nil {
  let _ =
    list.index_map(rows, fn(row, index) {
      list.each([0, 2], fn(label_col) {
        case list.drop(row, label_col) {
          [label, _] -> {
            let value_col = label_col + 1
            // Field names are display only; only the value cell is editable.
            campy_wx.set_grid_read_only(
              shell,
              "inspector",
              index,
              label_col,
              True,
            )
            case label {
              "x" | "y" ->
                campy_wx.set_grid_number_cell(
                  shell,
                  "inspector",
                  index,
                  value_col,
                  0,
                )
              "w" | "h" ->
                campy_wx.set_grid_number_cell(
                  shell,
                  "inspector",
                  index,
                  value_col,
                  campy_design.min_size,
                )
              _ ->
                campy_wx.set_grid_text_cell(
                  shell,
                  "inspector",
                  index,
                  value_col,
                )
            }
            campy_wx.set_grid_read_only(
              shell,
              "inspector",
              index,
              value_col,
              read_only || index == 0,
            )
          }
          _ -> Nil
        }
      })
    })
  Nil
}

fn set_console(shell: campy_wx.Shell, state: model.State) {
  campy_wx.set_editor(shell, "console", model.console_text(state), True)
}

fn selection_rect(state: model.State) -> Option(#(Int, Int, Int, Int)) {
  case selection_items(state) {
    [] -> None
    [#(_, first), ..rest] ->
      Some(
        list.fold(rest, first, fn(acc, item) {
          let #(_, rect) = item
          union(acc, rect)
        }),
      )
  }
}

fn union(
  a: #(Int, Int, Int, Int),
  b: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int) {
  let #(ax, ay, aw, ah) = a
  let #(bx, by, bw, bh) = b
  let x = int.min(ax, bx)
  let y = int.min(ay, by)
  let right = int.max(ax + aw, bx + bw)
  let bottom = int.max(ay + ah, by + bh)
  #(x, y, right - x, bottom - y)
}

fn status_text(state: model.State) -> String {
  case state.status {
    "" -> model.status_line(state)
    status -> model.status_line(state) <> "  —  " <> status
  }
}

pub fn tree_items(state: model.State) -> List(plan.TreeItem) {
  [
    plan.TreeItem(
      "project",
      state.project.title,
      list.map(state.project.modules, fn(module) {
        plan.TreeItem(module.slug, module.slug, [])
      }),
    ),
  ]
}

pub fn inspector_rows(state: model.State) -> List(List(String)) {
  case state.selection {
    [] -> summary_rows(state)
    [id] -> control_rows(state, id)
    ids -> multi_rows(state, ids)
  }
}

/// Event keys for the events list beside the inspector. Only a single selected
/// control contributes; the list stays empty for multi-selection.
pub fn event_items(state: model.State) -> List(String) {
  model.selected_events(state)
}

/// Multi-selection shows only properties every selected control shares; a
/// differing value is blank. Geometry stays absolute (invariant 8), so nested
/// controls compare their canvas rectangles, not parent-relative props.
fn multi_rows(state: model.State, ids: List(String)) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> summary_rows(state)
    Ok(module) -> {
      let nodes =
        list.filter_map(ids, fn(id) {
          case campy_design.find_node(module.form.view, id) {
            Some(node) -> Ok(node)
            None -> Error(Nil)
          }
        })
      let rects =
        list.filter_map(ids, fn(id) {
          case campy_design.absolute(module.form.view, id) {
            Some(rect) -> Ok(rect)
            None -> Error(Nil)
          }
        })

      [
        ["Field", "Value", "Field", "Value"],
        [
          "selected",
          int.to_string(list.length(ids)),
          "kind",
          common(list.map(nodes, fn(node) { node.kind })),
        ],
        [
          "parent",
          common(
            list.map(nodes, fn(node) { parent_label(module.form.view, node.id) }),
          ),
          "x",
          common(list.map(rects, fn(rect) { int.to_string(rect.x) })),
        ],
        [
          "y",
          common(list.map(rects, fn(rect) { int.to_string(rect.y) })),
          "w",
          common(list.map(rects, fn(rect) { int.to_string(rect.w) })),
        ],
        [
          "h",
          common(list.map(rects, fn(rect) { int.to_string(rect.h) })),
          "text",
          common(list.map(nodes, text_of)),
        ],
      ]
    }
  }
}

fn common(values: List(String)) -> String {
  case values {
    [] -> ""
    [first, ..rest] ->
      case list.all(rest, fn(value) { value == first }) {
        True -> first
        False -> ""
      }
  }
}

fn summary_rows(state: model.State) -> List(List(String)) {
  [
    ["Field", "Value", "Field", "Value"],
    [
      "Project",
      state.project.title,
      "Module",
      active_slug(state),
    ],
    [
      "Tabs",
      int.to_string(list.length(state.open_tabs)),
      "History",
      int.to_string(list.length(state.undo)),
    ],
  ]
}

fn control_rows(state: model.State, id: String) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> summary_rows(state)
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        None -> summary_rows(state)
        Some(node) -> {
          let rect = case campy_design.absolute(module.form.view, id) {
            Some(rect) -> rect
            None -> campy_design.Rect(0, 0, 0, 0)
          }
          [
            ["Field", "Value", "Field", "Value"],
            ["id", id, "kind", node.kind],
            [
              "parent",
              parent_label(module.form.view, id),
              "x",
              int.to_string(rect.x),
            ],
            ["y", int.to_string(rect.y), "w", int.to_string(rect.w)],
            ["h", int.to_string(rect.h), "text", text_of(node)],
          ]
        }
      }
  }
}

fn parent_label(root: Node, id: String) -> String {
  case campy_design.parent_of(root, id) {
    Some(parent) -> parent
    None -> "—"
  }
}

fn text_of(node: Node) -> String {
  case campy_view.prop(node, "text") {
    Ok(VText(text)) -> text
    _ -> ""
  }
}

fn active_slug(state: model.State) -> String {
  case state.active {
    Some(slug) -> slug
    None -> "—"
  }
}

fn canvas_node(state: model.State) -> Node {
  case model.active_module(state) {
    Ok(module) -> campy_design.design_view(module.form.view, "canvas")
    Error(_) ->
      campy_view.node("canvas", "canvas")
      |> campy_view.with_props([#("h", VInt(300)), #("w", VInt(400))])
      |> campy_view.with_events(["select"])
  }
}

fn view(state: model.State) -> Node {
  campy_view.node("window", "main")
  |> campy_view.with_props([
    #("title", VText("Campy")),
    #("w", VInt(980)),
    #("h", VInt(760)),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    menubar(),
    toolbar(),
    status(),
    body(state),
    inspector(),
  ])
}

fn menubar() -> Node {
  campy_view.node("menubar", "menubar")
  |> campy_view.with_children([
    menu("file-menu", "File", [
      menu_item("menu-save", "Save"),
      menu_item("menu-quit", "Quit"),
    ]),
    menu("edit-menu", "Edit", [
      menu_item("menu-undo", "Undo"),
      menu_item("menu-redo", "Redo"),
      menu_item("menu-cut", "Cut"),
      menu_item("menu-copy", "Copy"),
      menu_item("menu-paste", "Paste"),
      menu_item("menu-duplicate", "Duplicate"),
      menu_item("menu-delete", "Delete"),
      menu_item("menu-front", "Bring to front"),
      menu_item("menu-back", "Send to back"),
      menu_item("menu-cancel-place", "Cancel placement"),
    ]),
    menu("view-menu", "View", [menu_item("menu-toggle", "Toggle code")]),
  ])
}

fn menu(id: String, label: String, items: List(Node)) -> Node {
  campy_view.node("menu", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_children(items)
}

fn menu_item(id: String, label: String) -> Node {
  campy_view.node("menuitem", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn toolbar() -> Node {
  campy_view.node("toolbar", "toolbar")
  |> campy_view.with_children([
    tool("tool-save", "Save"),
    tool("tool-undo", "Undo"),
    tool("tool-redo", "Redo"),
    tool("tool-toggle", "Toggle"),
    tool("tool-copy", "Copy"),
    tool("tool-paste", "Paste"),
    tool("tool-duplicate", "Dup"),
    tool("tool-delete", "Delete"),
  ])
}

fn tool(id: String, label: String) -> Node {
  campy_view.node("tool", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn status() -> Node {
  campy_view.node("status", "status")
  |> campy_view.with_props([#("text", VText("Ready"))])
}

fn body(state: model.State) -> Node {
  campy_view.node("panel", "body")
  |> campy_view.with_props([
    #("layout", VText("row")),
    #("border", VInt(4)),
    #("grow", VBool(True)),
  ])
  |> campy_view.with_children([left_pane(), right_pane(state)])
}

fn left_pane() -> Node {
  campy_view.node("panel", "left")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(4)),
    #("w", VInt(220)),
  ])
  |> campy_view.with_children([
    campy_view.node("tree", "modules")
      |> campy_view.with_props([#("grow", VBool(True))])
      |> campy_view.with_events(["select"]),
    campy_view.node("label", "palette-title")
      |> campy_view.with_props([#("text", VText("Widgets"))]),
    palette(),
  ])
}

fn palette() -> Node {
  campy_view.node("list", "palette")
  |> campy_view.with_props([
    #("h", VInt(210)),
    #("items", VList(list.map(palette_labels(), VText))),
  ])
  |> campy_view.with_events(["change"])
}

pub fn palette_labels() -> List(String) {
  list.map(campy_catalog.all(), fn(widget) { widget.label })
}

fn right_pane(state: model.State) -> Node {
  campy_view.node("panel", "right")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("grow", VBool(True)),
  ])
  |> campy_view.with_children([
    campy_view.node("notebook", "tabs")
      |> campy_view.with_props([#("grow", VBool(True))])
      |> campy_view.with_events(["change"])
      |> campy_view.with_children([
        form_page(state),
        code_page(),
      ]),
    campy_view.node("editor", "console")
      |> campy_view.with_props([#("h", VInt(120))])
      |> campy_view.with_events([]),
  ])
}

fn form_page(state: model.State) -> Node {
  campy_view.node("page", "page-form")
  |> campy_view.with_props([
    #("text", VText("Form")),
    #("layout", VText("free")),
  ])
  |> campy_view.with_children([canvas_node(state)])
}

fn code_page() -> Node {
  campy_view.node("page", "page-code")
  |> campy_view.with_props([
    #("text", VText("Code")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("editor", "code")
    |> campy_view.with_props([#("grow", VBool(True))])
    |> campy_view.with_events([]),
  ])
}

fn inspector() -> Node {
  campy_view.node("panel", "inspector-pane")
  |> campy_view.with_props([
    #("layout", VText("row")),
    #("h", VInt(170)),
    #("border", VInt(0)),
  ])
  |> campy_view.with_children([
    campy_view.node("grid", "inspector")
      |> campy_view.with_props([#("grow", VBool(True))])
      |> campy_view.with_events(["change"]),
    campy_view.node("panel", "events-pane")
      |> campy_view.with_props([
        #("layout", VText("column")),
        #("w", VInt(220)),
        #("border", VInt(4)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "events-title")
          |> campy_view.with_props([#("text", VText("Events"))]),
        campy_view.node("list", "events")
          |> campy_view.with_props([#("grow", VBool(True))])
          |> campy_view.with_events(["change"]),
      ]),
  ])
}
