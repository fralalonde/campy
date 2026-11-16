//// Pure helpers shared by the wx renderer and its tests.
////
//// Nothing here touches wx: node interpretation, layout classification,
//// property diffing, and event-key mapping are ordinary data functions.

import campy_view.{type Node, type Value, VInt, VList, VText}
import gleam/dict
import gleam/list

pub type Layout {
  Free
  Column
  Row
}

pub type TreeItem {
  TreeItem(key: String, label: String, children: List(TreeItem))
}

pub fn layout(node: Node) -> Layout {
  case prop_text(node, "layout") {
    Ok("column") -> Column
    Ok("row") -> Row
    _ -> Free
  }
}

pub fn layout_name(node: Node) -> String {
  case layout(node) {
    Column -> "column"
    Row -> "row"
    Free -> "free"
  }
}

pub fn border(node: Node) -> Int {
  prop_int(node, "border") |> unwrap_or(0)
}

pub fn prop(node: Node, name: String) -> Result(Value, Nil) {
  campy_view.prop(node, name)
}

/// Property lookup on an already-extracted property list. The renderer stores
/// the current props on each widget, so updates do not need a fresh `Node`.
pub fn value_of(
  props: List(#(String, Value)),
  name: String,
) -> Result(Value, Nil) {
  props
  |> dict.from_list
  |> dict.get(name)
}

pub fn text_of(
  props: List(#(String, Value)),
  name: String,
) -> Result(String, Nil) {
  case value_of(props, name) {
    Ok(VText(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

pub fn int_of(props: List(#(String, Value)), name: String) -> Result(Int, Nil) {
  case value_of(props, name) {
    Ok(VInt(number)) -> Ok(number)
    _ -> Error(Nil)
  }
}

pub fn bool_of(
  props: List(#(String, Value)),
  name: String,
) -> Result(Bool, Nil) {
  case value_of(props, name) {
    Ok(campy_view.VBool(flag)) -> Ok(flag)
    _ -> Error(Nil)
  }
}

pub fn items_of(props: List(#(String, Value)), name: String) -> List(String) {
  case value_of(props, name) {
    Ok(VList(items)) ->
      list.filter_map(items, fn(item) {
        case item {
          VText(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

pub fn prop_text(node: Node, name: String) -> Result(String, Nil) {
  text_of(node.props, name)
}

pub fn prop_int(node: Node, name: String) -> Result(Int, Nil) {
  int_of(node.props, name)
}

pub fn prop_bool(node: Node, name: String) -> Result(Bool, Nil) {
  bool_of(node.props, name)
}

pub fn prop_items(node: Node, name: String) -> List(String) {
  items_of(node.props, name)
}

pub fn unwrap_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// Properties that differ from the previous document. A missing previous
/// property counts as changed.
pub fn changed_props(
  previous: List(#(String, Value)),
  next: List(#(String, Value)),
) -> List(#(String, Value)) {
  let previous = dict.from_list(previous)

  next
  |> list.filter(fn(field) {
    case dict.get(previous, field.0) {
      Ok(value) -> value != field.1
      Error(Nil) -> True
    }
  })
}

/// The view event a widget of this kind emits on its connected wx event.
pub fn event_key(kind: String) -> String {
  case kind {
    "window" -> "close"
    "button" | "checkbox" | "radio" | "menu" -> "click"
    "text" | "memo" | "choice" | "list" | "slider" | "notebook" | "grid" ->
      "change"
    "tree" -> "select"
    _ -> "click"
  }
}

pub fn is_container(kind: String) -> Bool {
  case kind {
    "window" | "form" | "panel" | "group" | "page" -> True
    _ -> False
  }
}
