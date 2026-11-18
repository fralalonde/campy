//// Shell demo: menus, toolbar, status bar, tree, tabs, Scintilla, grid.
////
//// Run: `gleam run -m campy_wx/shell_demo` (display needed).
//// Smoke: CAMPY_WX_SMOKE=1 ... fills every region and exits 0.

import campy_view.{VBool, VInt, VText}
import campy_wx
import campy_wx/plan
import gleam/int
import gleam/io

pub fn main() {
  case campy_wx.getenv("CAMPY_WX_SMOKE") {
    "1" -> smoke()
    _ -> interactive()
  }
}

fn view() -> campy_view.Node {
  campy_view.node("window", "main")
  |> campy_view.with_props([
    #("title", VText("Campy shell demo")),
    #("w", VInt(820)),
    #("h", VInt(600)),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    menubar(),
    toolbar(),
    status(),
    campy_view.node("panel", "body")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("grow", VBool(True)),
      ])
      |> campy_view.with_children([
        campy_view.node("tree", "tree")
          |> campy_view.with_props([#("w", VInt(220))])
          |> campy_view.with_events(["select"]),
        editor_tabs(),
      ]),
    campy_view.node("grid", "inspector")
      |> campy_view.with_props([#("h", VInt(120))])
      |> campy_view.with_events(["change"]),
  ])
}

fn menubar() -> campy_view.Node {
  campy_view.node("menubar", "menubar")
  |> campy_view.with_children([
    campy_view.node("menu", "file-menu")
      |> campy_view.with_props([#("text", VText("File"))])
      |> campy_view.with_children([
        menu_item("open", "Open…"),
        menu_item("save", "Save"),
        menu_item("quit", "Quit"),
      ]),
    campy_view.node("menu", "help-menu")
      |> campy_view.with_props([#("text", VText("Help"))])
      |> campy_view.with_children([menu_item("about", "About")]),
  ])
}

fn menu_item(id: String, label: String) -> campy_view.Node {
  campy_view.node("menuitem", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn toolbar() -> campy_view.Node {
  campy_view.node("toolbar", "toolbar")
  |> campy_view.with_children([
    tool("run", "Run"),
    tool("reload", "Reload"),
    tool("stop", "Stop"),
  ])
}

fn tool(id: String, label: String) -> campy_view.Node {
  campy_view.node("tool", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn status() -> campy_view.Node {
  campy_view.node("status", "status")
  |> campy_view.with_props([#("text", VText("Ready"))])
}

fn editor_tabs() -> campy_view.Node {
  campy_view.node("notebook", "tabs")
  |> campy_view.with_props([#("grow", VBool(True))])
  |> campy_view.with_events(["change"])
  |> campy_view.with_children([
    campy_view.node("page", "page-main")
    |> campy_view.with_props([
      #("text", VText("Editor")),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      campy_view.node("editor", "code")
      |> campy_view.with_props([#("grow", VBool(True))]),
    ]),
  ])
}

fn interactive() {
  let shell = campy_wx.start("Campy shell demo", 820, 600)
  let assert Ok(shell) = campy_wx.mount(shell, view())
  fill(shell)
  loop(shell)
}

fn smoke() {
  let shell = campy_wx.start("Campy shell smoke", 820, 600)
  let started = campy_wx.now_ms()
  let assert Ok(shell) = campy_wx.mount(shell, view())
  io.println(
    "[shell] mount " <> int.to_string(campy_wx.now_ms() - started) <> "ms",
  )
  fill(shell)
  campy_wx.set_status(shell, "Smoke loaded")
  campy_wx.close(shell)
  io.println("[shell] smoke ok")
}

fn fill(shell: campy_wx.Shell) {
  campy_wx.set_tree(shell, "tree", [
    plan.TreeItem("project", "campy", [
      plan.TreeItem("m1", "cat_cafe", []),
      plan.TreeItem("m2", "ccl_widgets", []),
    ]),
  ])

  campy_wx.set_grid(shell, "inspector", [
    ["Property", "Value"],
    ["text", "Hello"],
    ["x", "16"],
    ["y", "16"],
  ])

  campy_wx.set_editor(
    shell,
    "code",
    "import campy_app\n\npub fn init() {\n  Nil\n}\n",
    False,
  )
}

fn loop(shell: campy_wx.Shell) {
  case campy_wx.next(shell, 100) {
    campy_wx.Closed -> {
      campy_wx.close(shell)
      io.println("[shell] closed")
    }
    campy_wx.Event(id, key, value) -> {
      io.println("[shell] event " <> id <> "." <> key <> " = " <> render(value))
      case id {
        "quit" -> {
          campy_wx.close(shell)
          io.println("[shell] quit")
        }
        _ -> loop(shell)
      }
    }
    campy_wx.Paint(id) -> {
      campy_wx.paint(shell, id)
      loop(shell)
    }
    campy_wx.MouseHandle(_, _, _, _) -> loop(shell)
    campy_wx.Mouse(_, _, _, _, _) -> loop(shell)
    campy_wx.KeyPressed(_) -> loop(shell)
    campy_wx.Accelerator(_) -> loop(shell)
    campy_wx.FrameMoved -> loop(shell)
    campy_wx.Message(_message) -> loop(shell)
    campy_wx.Idle -> loop(shell)
  }
}

fn render(value: campy_view.Value) -> String {
  case value {
    VText(text) -> text
    VInt(number) -> int.to_string(number)
    VBool(flag) ->
      case flag {
        True -> "true"
        False -> "false"
      }
    _ -> "[value]"
  }
}
