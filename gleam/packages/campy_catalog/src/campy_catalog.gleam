//// Target-neutral widget catalog.
////
//// The palette, the designer defaults, and (later) generated handlers all need
//// the same answer to "what widgets exist, what do they look like fresh, and
//// which events do they declare". None of that depends on wx: this package is
//// plain data so a future HTML renderer can reuse it.
////
//// `make`/`make_at` build ordinary `campy_view.Node`s with the catalog's default
//// properties. They do not include geometry unless asked, so the designer can
//// place a control exactly where it was dropped.

import campy_view.{type Node, type Value, VBool, VInt, VList, VText}
import gleam/int
import gleam/list
import gleam/result

pub type Widget {
  Widget(kind: String, label: String, category: String, events: List(String))
}

/// Palette order. Kinds are stable document vocabulary; labels are UI only.
pub fn all() -> List(Widget) {
  [
    Widget("panel", "Panel", "Layout", []),
    Widget("group", "Group", "Layout", []),
    Widget("notebook", "Notebook", "Layout", []),
    Widget("page", "Notebook page", "Layout", []),
    Widget("label", "Label", "Display", []),
    Widget("button", "Button", "Input", ["click"]),
    Widget("text", "Text field", "Input", ["change"]),
    Widget("memo", "Memo", "Input", ["change"]),
    Widget("checkbox", "Checkbox", "Input", ["click"]),
    Widget("radio", "Radio button", "Input", ["click"]),
    Widget("choice", "Choice", "Input", ["change"]),
    Widget("list", "List box", "Input", ["change"]),
    Widget("slider", "Slider", "Input", ["change"]),
    Widget("progress", "Progress bar", "Display", []),
    Widget("picture", "Picture", "Display", []),
    Widget("tree", "Tree", "Data", ["select"]),
    Widget("grid", "Grid", "Data", ["change"]),
    Widget("editor", "Editor", "Data", ["change"]),
  ]
}

pub fn find(kind: String) -> Result(Widget, String) {
  case list.find(all(), fn(widget) { widget.kind == kind }) {
    Ok(widget) -> Ok(widget)
    Error(Nil) -> Error("unknown widget kind: " <> kind)
  }
}

pub fn label_of(kind: String) -> String {
  case find(kind) {
    Ok(widget) -> widget.label
    Error(_) -> kind
  }
}

/// Whether the designer may drop children into this kind. The form/window root
/// is a container too, but it is never offered as a palette item. A notebook
/// itself does not accept drops: new controls belong on one of its pages, so
/// dropping aims at the page under the cursor.
pub fn accepts_children(kind: String) -> Bool {
  case kind {
    "form" | "window" | "panel" | "group" | "page" -> True
    _ -> False
  }
}

/// The events a fresh control of this kind declares, in catalog order.
pub fn events(kind: String) -> List(String) {
  case find(kind) {
    Ok(widget) -> widget.events
    Error(_) -> []
  }
}

pub fn default_w(kind: String) -> Int {
  case kind {
    "label" -> 100
    "button" -> 100
    "text" -> 160
    "memo" -> 200
    "checkbox" | "radio" -> 110
    "choice" -> 140
    "list" -> 180
    "slider" -> 180
    "progress" -> 180
    "panel" | "group" -> 240
    "picture" -> 120
    "tree" -> 200
    "grid" -> 200
    "notebook" -> 320
    "page" -> 300
    "editor" -> 320
    "form" | "window" -> 640
    _ -> 100
  }
}

pub fn default_h(kind: String) -> Int {
  case kind {
    "label" -> 20
    "button" -> 30
    "text" -> 28
    "memo" -> 100
    "checkbox" | "radio" -> 24
    "choice" -> 28
    "list" -> 120
    "slider" -> 28
    "progress" -> 20
    "panel" | "group" -> 160
    "picture" -> 120
    "tree" -> 160
    "grid" -> 120
    "notebook" -> 200
    "page" -> 160
    "editor" -> 200
    "form" | "window" -> 480
    _ -> 28
  }
}

/// A fresh control at the origin with the catalog's default properties.
pub fn make(kind: String, id: String) -> Result(Node, String) {
  use widget <- result.try(find(kind))

  let props =
    [#("w", VInt(default_w(kind))), #("h", VInt(default_h(kind)))]
    |> list.append(default_props(kind))

  let node =
    campy_view.node(kind, id)
    |> campy_view.with_props(props)
    |> campy_view.with_events(widget.events)

  // A notebook is useless without a page: give a fresh one its first page.
  case kind {
    "notebook" ->
      Ok(
        campy_view.with_children(node, [
          campy_view.node("page", id <> "-p1")
          |> campy_view.with_props([
            #("x", VInt(0)),
            #("y", VInt(0)),
            #("w", VInt(default_w("notebook") - 8)),
            #("h", VInt(default_h("notebook") - 32)),
            #("text", VText("Page")),
            #("layout", VText("column")),
          ]),
        ]),
      )
    _ -> Ok(node)
  }
}

/// A fresh control with explicit geometry. Coordinates are relative to the
/// parent container chosen by the caller.
pub fn make_at(
  kind: String,
  id: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> Result(Node, String) {
  use node <- result.try(make(kind, id))

  Ok(
    node
    |> upsert("x", VInt(int.max(0, x)))
    |> upsert("y", VInt(int.max(0, y)))
    |> upsert("w", VInt(int.max(w, 1)))
    |> upsert("h", VInt(int.max(h, 1))),
  )
}

pub fn default_props(kind: String) -> List(#(String, Value)) {
  case kind {
    "label" -> [#("text", VText("Label"))]
    "button" -> [#("text", VText("Button"))]
    "checkbox" -> [#("text", VText("Checkbox")), #("value", VBool(False))]
    "radio" -> [#("text", VText("Radio")), #("value", VBool(False))]
    "text" | "memo" -> [#("text", VText(""))]
    "choice" | "list" -> [
      #("items", VList([VText("One"), VText("Two")])),
      #("selection", VInt(0)),
    ]
    "slider" | "progress" -> [
      #("value", VInt(0)),
      #("min", VInt(0)),
      #("max", VInt(100)),
    ]
    "panel" | "group" -> [#("layout", VText("free"))]
    "notebook" -> [#("layout", VText("free"))]
    "page" -> [#("text", VText("Page")), #("layout", VText("column"))]
    _ -> []
  }
}

fn upsert(node: Node, name: String, value: Value) -> Node {
  let props = list.filter(node.props, fn(prop) { prop.0 != name })
  campy_view.with_props(node, list.append(props, [#(name, value)]))
}
