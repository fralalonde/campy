//// Campy IDE shell on wx.
////
//// Loads a project directory, renders the shell view, and forwards wx events
//// into `campy_ide_model`. There is no document logic here: the model decides,
//// this module renders and dispatches.
////
//// Run: `CAMPY_PROJECT=examples/demo gleam run` from this directory.
//// Smoke: `CAMPY_WX_SMOKE=1 CAMPY_PROJECT=../..` ... (no display loop).

import campy_ide_model as model
import campy_project
import campy_view.{type Node, VBool, VInt, VText}
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
  let shell = campy_wx.start("Campy", 980, 680)
  let assert Ok(shell) = campy_wx.mount(shell, view())

  let state = model.new(project) |> model.update(model.Log("Loaded " <> dir))

  refresh(shell, None, state)
  loop(shell, state, dir)
}

fn smoke(project: campy_project.Project, dir: String) {
  let shell = campy_wx.start("Campy smoke", 980, 680)
  let started = campy_wx.now_ms()
  let assert Ok(shell) = campy_wx.mount(shell, view())
  io.println(
    "[ide] mount " <> int.to_string(campy_wx.now_ms() - started) <> "ms",
  )

  let state = model.new(project) |> model.update(model.Log("Loaded " <> dir))

  refresh(shell, None, state)

  let previous = state
  let state = case project.modules {
    [_, second, ..] -> model.update(state, model.OpenModule(second.slug))
    _ -> state
  }
  refresh(shell, Some(previous), state)
  io.println(
    "[ide] active="
    <> active_slug(state)
    <> " console="
    <> int.to_string(list.length(state.console)),
  )
  io.println("[ide] smoke ok")

  campy_wx.close(shell)
}

fn loop(shell: campy_wx.Shell, state: model.State, dir: String) {
  case campy_wx.next(shell, 100) {
    campy_wx.Closed -> {
      campy_wx.close(shell)
      io.println("[ide] closed")
    }
    campy_wx.Event(id, key, value) -> {
      case id {
        "menu-quit" -> {
          campy_wx.close(shell)
          io.println("[ide] quit")
        }
        _ -> {
          let previous = state
          let state = handle(state, dir, id, key, value)
          refresh(shell, Some(previous), state)
          loop(shell, state, dir)
        }
      }
    }
    campy_wx.Message(_message) -> loop(shell, state, dir)
    campy_wx.Idle -> loop(shell, state, dir)
  }
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
      case key {
        "select" -> open_key(state, value)
        _ -> state
      }
    _ -> model.update(state, model.Log("event " <> id <> "." <> key))
  }
}

fn open_key(state: model.State, value: campy_view.Value) -> model.State {
  case value {
    VText(key) ->
      case campy_project.module(state.project, key) {
        Ok(_module) -> model.update(state, model.OpenModule(key))
        Error(_) -> model.update(state, model.Log("not a module: " <> key))
      }
    _ -> state
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
    }
  }

  campy_wx.set_grid(shell, "inspector", inspector_rows(state))
  campy_wx.set_status(shell, status_text(state))
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
  [
    ["Field", "Value"],
    ["Project", state.project.title],
    ["Module", active_slug(state)],
    ["Tabs", int.to_string(list.length(state.open_tabs))],
    ["History", int.to_string(list.length(state.undo))],
  ]
}

fn active_slug(state: model.State) -> String {
  case state.active {
    Some(slug) -> slug
    None -> "—"
  }
}

fn view() -> Node {
  campy_view.node("window", "main")
  |> campy_view.with_props([
    #("title", VText("Campy")),
    #("w", VInt(980)),
    #("h", VInt(680)),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    menubar(),
    toolbar(),
    status(),
    body(),
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

fn body() -> Node {
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
    right_pane(),
  ])
}

fn right_pane() -> Node {
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
        campy_view.node("page", "page-code")
        |> campy_view.with_props([
          #("text", VText("Code")),
          #("layout", VText("column")),
        ])
        |> campy_view.with_children([
          campy_view.node("editor", "code")
          |> campy_view.with_props([#("grow", VBool(True))])
          |> campy_view.with_events([]),
        ]),
      ]),
    campy_view.node("editor", "console")
      |> campy_view.with_props([#("h", VInt(150))])
      |> campy_view.with_events([]),
  ])
}

fn inspector() -> Node {
  campy_view.node("grid", "inspector")
  |> campy_view.with_props([#("h", VInt(110))])
  |> campy_view.with_events(["change"])
}
