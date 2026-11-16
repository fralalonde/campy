//// Campy IDE shell on wx.
////
//// Loads a project directory, renders the shell view, and forwards wx events
//// into `campy_ide_model`. Document logic lives in the model; this module
//// builds the view tree, applies its diffs, and fills data-driven panes.
////
//// Run: `CAMPY_PROJECT=examples/demo gleam run` from this directory.
//// Smoke: `CAMPY_WX_SMOKE=1` runs mount/switch/select/close without a loop.

import campy_design
import campy_ide_model as model
import campy_project
import campy_view.{type Node, VBool, VInt, VText}
import campy_view/diff
import campy_wx
import campy_wx/plan
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}

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
    campy_wx.Mouse(id, x, y) -> {
      let previous = state
      let state = select_at(state, id, x, y)
      refresh(shell, Some(previous), state)
      loop(shell, state, current, dir, NoDrag)
    }
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
    "motion" ->
      case drag_rect(drag, x, y) {
        Some(#(id, #(rx, ry, rw, rh))) -> {
          campy_wx.preview_rect(shell, id, rx, ry, rw, rh)
          loop(shell, state, current, dir, drag)
        }
        None -> loop(shell, state, current, dir, drag)
      }
    "left_up" -> {
      campy_wx.release_handle(shell, role)
      case drag_rect(drag, x, y) {
        Some(#(id, rect)) -> {
          let previous = state
          let state = commit_rect(state, id, rect)
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
        None -> loop(shell, state, current, dir, NoDrag)
      }
    }
    _ -> loop(shell, state, current, dir, drag)
  }
}

fn start_drag(state: model.State, role: Int, x: Int, y: Int) -> Drag {
  case state.selection, selection_rect(state) {
    [id, ..], Some(rect) ->
      case role == 8 {
        True -> MoveDrag(id, x, y, rect)
        False -> ResizeDrag(id, role, x, y, rect)
      }
    _, _ -> NoDrag
  }
}

fn drag_rect(
  drag: Drag,
  x: Int,
  y: Int,
) -> Option(#(String, #(Int, Int, Int, Int))) {
  case drag {
    NoDrag -> None
    MoveDrag(id, start_x, start_y, #(rx, ry, rw, rh)) ->
      Some(#(id, #(rx + x - start_x, ry + y - start_y, rw, rh)))
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
      Some(#(id, #(left, top, right - left, bottom - top)))
    }
  }
}

fn commit_rect(
  state: model.State,
  id: String,
  rect: #(Int, Int, Int, Int),
) -> model.State {
  case model.active_module(state) {
    Error(_) -> state
    Ok(module) -> {
      let #(x, y, width, height) = rect
      let view =
        campy_design.set_rect(
          module.form.view,
          id,
          campy_design.Rect(x: x, y: y, w: width, h: height),
        )
      let document =
        campy_view.Document(
          schema: module.form.schema,
          view: view,
          extra: module.form.extra,
        )
      let updated =
        campy_project.Module(
          slug: module.slug,
          form: document,
          handlers: module.handlers,
        )
      let modules =
        list.map(state.project.modules, fn(candidate) {
          case candidate.slug == module.slug {
            True -> updated
            False -> candidate
          }
        })
      model.commit(
        state,
        campy_project.Project(
          title: state.project.title,
          modules: modules,
          extra: state.project.extra,
        ),
      )
    }
  }
}

type Drag {
  NoDrag
  MoveDrag(id: String, start_x: Int, start_y: Int, rect: #(Int, Int, Int, Int))
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
    "modules" ->
      case key, value {
        "select", VText(slug) -> tree_selected(state, slug)
        _, _ -> state
      }
    _ -> select_or_log(state, id, key)
  }
}

fn select_or_log(state: model.State, id: String, key: String) -> model.State {
  case id {
    "canvas" -> state
    _ -> select_control(state, id, key)
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
fn select_at(state: model.State, id: String, x: Int, y: Int) -> model.State {
  case id {
    "canvas" ->
      case model.active_module(state) {
        Error(_) -> state
        Ok(module) -> {
          let layout = campy_design.resolve(module.form.view)
          case campy_design.at(layout, x, y) {
            Some(placed) ->
              case placed.id == "canvas" {
                True -> model.select_controls(state, [])
                False -> model.select_controls(state, [placed.id])
              }
            None -> model.select_controls(state, [])
          }
        }
      }
    _ -> select_control(state, id, "select")
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
      case previous.active == state.active {
        False -> set_code(shell, state)
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

  campy_wx.set_grid(shell, "inspector", inspector_rows(state))
  campy_wx.set_status(shell, status_text(state))
  campy_wx.show_selection(shell, selection_rect(state))
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

fn set_console(shell: campy_wx.Shell, state: model.State) {
  campy_wx.set_editor(shell, "console", model.console_text(state), True)
}

fn selection_rect(state: model.State) -> Option(#(Int, Int, Int, Int)) {
  case state.selection {
    [] -> None
    [id, ..] ->
      case model.active_module(state) {
        Error(_) -> None
        Ok(module) ->
          case campy_design.placed(campy_design.resolve(module.form.view), id) {
            Some(placed) ->
              Some(#(placed.rect.x, placed.rect.y, placed.rect.w, placed.rect.h))
            None -> None
          }
      }
  }
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
    [id, ..] -> control_rows(state, id)
  }
}

fn summary_rows(state: model.State) -> List(List(String)) {
  [
    ["Field", "Value"],
    ["Project", state.project.title],
    ["Module", active_slug(state)],
    ["Tabs", int.to_string(list.length(state.open_tabs))],
    ["History", int.to_string(list.length(state.undo))],
  ]
}

fn control_rows(state: model.State, id: String) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> summary_rows(state)
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        None -> summary_rows(state)
        Some(node) -> [
          ["Field", "Value"],
          ["id", id],
          ["kind", node.kind],
          ["x", int.to_string(campy_design.int_prop(node, "x", 0))],
          ["y", int.to_string(campy_design.int_prop(node, "y", 0))],
          ["w", int.to_string(campy_design.int_prop(node, "w", 0))],
          ["h", int.to_string(campy_design.int_prop(node, "h", 0))],
          ["text", text_of(node)],
        ]
      }
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
  |> campy_view.with_children([
    campy_view.node("tree", "modules")
      |> campy_view.with_props([#("w", VInt(220))])
      |> campy_view.with_events(["select"]),
    right_pane(state),
  ])
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
  campy_view.node("grid", "inspector")
  |> campy_view.with_props([#("h", VInt(170))])
  |> campy_view.with_events(["change"])
}
