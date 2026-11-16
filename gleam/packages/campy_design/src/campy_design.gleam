//// Pure designer geometry.
////
//// A form is a nested view tree. The designer needs absolute rectangles to
//// paint the canvas, hit-test, and commit drags; the runtime renderer uses the
//// same rules for free layouts and delegates column/row to wx sizers. Keeping
//// the math here means the canvas and the inspector cannot drift.
////
//// Coordinates in the document are relative to the parent container (the form
//// root's origin is 0,0). Column/row children ignore x/y; free children honour
//// x/y/w/h and an optional alignment.

import campy_view.{type Node, type Value, VInt, VText}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Rect {
  Rect(x: Int, y: Int, w: Int, h: Int)
}

pub type Placed {
  Placed(
    id: String,
    kind: String,
    rect: Rect,
    parent: Option(String),
    container: Bool,
  )
}

pub type Layout {
  Layout(root: String, places: List(Placed))
}

pub const min_size = 8

pub fn resolve(root: Node) -> Layout {
  let rect =
    Rect(
      x: 0,
      y: 0,
      w: int_prop(root, "w", default_w(root.kind)),
      h: int_prop(root, "h", default_h(root.kind)),
    )

  let places = [
    Placed(
      id: root.id,
      kind: root.kind,
      rect: rect,
      parent: None,
      container: is_container(root.kind),
    ),
  ]

  Layout(root: root.id, places: resolve_children(root, rect, root.id, places))
}

fn resolve_children(
  node: Node,
  rect: Rect,
  parent_id: String,
  acc: List(Placed),
) -> List(Placed) {
  let inner = inset(rect, int_prop(node, "border", 0))

  case text_prop(node, "layout") {
    "column" -> column_children(node.children, inner, gap(node), parent_id, acc)
    "row" -> row_children(node.children, inner, gap(node), parent_id, acc)
    _ -> free_children(node.children, inner, parent_id, acc)
  }
}

fn free_children(
  children: List(Node),
  inner: Rect,
  parent_id: String,
  acc: List(Placed),
) -> List(Placed) {
  list.fold(children, acc, fn(acc, child) {
    add_child(child, free_rect(child, inner), parent_id, acc)
  })
}

fn column_children(
  children: List(Node),
  inner: Rect,
  gap: Int,
  parent_id: String,
  acc: List(Placed),
) -> List(Placed) {
  column_loop(children, inner, gap, parent_id, acc, inner.y)
}

fn column_loop(
  children: List(Node),
  inner: Rect,
  gap: Int,
  parent_id: String,
  acc: List(Placed),
  y: Int,
) -> List(Placed) {
  case children {
    [] -> acc
    [child, ..rest] -> {
      let height = int_prop(child, "h", default_h(child.kind))
      let rect = Rect(x: inner.x, y: y, w: inner.w, h: height)
      let acc = add_child(child, rect, parent_id, acc)
      column_loop(rest, inner, gap, parent_id, acc, y + height + gap)
    }
  }
}

fn row_children(
  children: List(Node),
  inner: Rect,
  gap: Int,
  parent_id: String,
  acc: List(Placed),
) -> List(Placed) {
  row_loop(children, inner, gap, parent_id, acc, inner.x)
}

fn row_loop(
  children: List(Node),
  inner: Rect,
  gap: Int,
  parent_id: String,
  acc: List(Placed),
  x: Int,
) -> List(Placed) {
  case children {
    [] -> acc
    [child, ..rest] -> {
      let width = int_prop(child, "w", default_w(child.kind))
      let rect = Rect(x: x, y: inner.y, w: width, h: inner.h)
      let acc = add_child(child, rect, parent_id, acc)
      row_loop(rest, inner, gap, parent_id, acc, x + width + gap)
    }
  }
}

fn add_child(
  child: Node,
  rect: Rect,
  parent_id: String,
  acc: List(Placed),
) -> List(Placed) {
  let acc =
    list.append(acc, [
      Placed(
        id: child.id,
        kind: child.kind,
        rect: rect,
        parent: Some(parent_id),
        container: is_container(child.kind),
      ),
    ])

  resolve_children(child, rect, child.id, acc)
}

fn free_rect(child: Node, inner: Rect) -> Rect {
  let width = int_prop(child, "w", default_w(child.kind))
  let height = int_prop(child, "h", default_h(child.kind))
  let x = int_prop(child, "x", 0)
  let y = int_prop(child, "y", 0)

  case text_prop(child, "align") {
    "top" -> Rect(x: inner.x, y: inner.y, w: inner.w, h: height)
    "bottom" ->
      Rect(x: inner.x, y: inner.y + inner.h - height, w: inner.w, h: height)
    "left" -> Rect(x: inner.x, y: inner.y, w: width, h: inner.h)
    "right" ->
      Rect(x: inner.x + inner.w - width, y: inner.y, w: width, h: inner.h)
    "client" | "fill" -> inner
    _ -> Rect(x: inner.x + x, y: inner.y + y, w: width, h: height)
  }
}

/// Topmost (last-painted) placed item containing the point.
pub fn at(layout: Layout, x: Int, y: Int) -> Option(Placed) {
  find_last(layout.places, fn(placed) { contains(placed.rect, x, y) })
}

/// Deepest container containing the point; the form root is the fallback.
pub fn container_at(layout: Layout, x: Int, y: Int) -> Option(Placed) {
  find_last(layout.places, fn(placed) {
    placed.container && contains(placed.rect, x, y)
  })
}

pub fn contains(rect: Rect, x: Int, y: Int) -> Bool {
  x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

fn find_last(items: List(a), matches: fn(a) -> Bool) -> Option(a) {
  case items {
    [] -> None
    [first, ..rest] ->
      case find_last(rest, matches) {
        Some(found) -> Some(found)
        None ->
          case matches(first) {
            True -> Some(first)
            False -> None
          }
      }
  }
}

/// Move a control by a delta, expressed in its parent's coordinates. Aligned
/// controls become free-positioned (alignment is cleared) on an explicit drag.
pub fn move(root: Node, id: String, dx: Int, dy: Int) -> Node {
  update_node(root, id, fn(node) {
    node
    |> set_prop("x", VInt(int_prop(node, "x", 0) + dx))
    |> set_prop("y", VInt(int_prop(node, "y", 0) + dy))
    |> set_prop("align", VText("none"))
  })
}

/// Resize a control by a delta. Sizes never fall below `min_size`.
pub fn resize(root: Node, id: String, dw: Int, dh: Int) -> Node {
  update_node(root, id, fn(node) {
    node
    |> set_prop(
      "w",
      VInt(int.max(int_prop(node, "w", default_w(node.kind)) + dw, min_size)),
    )
    |> set_prop(
      "h",
      VInt(int.max(int_prop(node, "h", default_h(node.kind)) + dh, min_size)),
    )
  })
}

/// Set an absolute rectangle for a control, expressed in its parent's
/// coordinates. The canvas converts pointer deltas with this.
pub fn set_rect(root: Node, id: String, rect: Rect) -> Node {
  update_node(root, id, fn(node) {
    node
    |> set_prop("x", VInt(rect.x))
    |> set_prop("y", VInt(rect.y))
    |> set_prop("w", VInt(int.max(rect.w, min_size)))
    |> set_prop("h", VInt(int.max(rect.h, min_size)))
    |> set_prop("align", VText("none"))
  })
}

fn update_node(node: Node, id: String, change: fn(Node) -> Node) -> Node {
  case node.id == id {
    True -> change(node)
    False ->
      campy_view.with_children(
        node,
        list.map(node.children, fn(child) { update_node(child, id, change) }),
      )
  }
}

fn set_prop(node: Node, name: String, value: Value) -> Node {
  let props = list.filter(node.props, fn(prop) { prop.0 != name })
  campy_view.with_props(node, list.append(props, [#(name, value)]))
}

fn inset(rect: Rect, amount: Int) -> Rect {
  Rect(
    x: rect.x + amount,
    y: rect.y + amount,
    w: int.max(rect.w - amount * 2, 0),
    h: int.max(rect.h - amount * 2, 0),
  )
}

fn gap(node: Node) -> Int {
  int_prop(node, "gap", 4)
}

pub fn is_container(kind: String) -> Bool {
  case kind {
    "window" | "form" | "panel" | "group" -> True
    _ -> False
  }
}

pub fn int_prop(node: Node, name: String, fallback: Int) -> Int {
  case campy_view.prop(node, name) {
    Ok(VInt(value)) -> value
    _ -> fallback
  }
}

fn text_prop(node: Node, name: String) -> String {
  case campy_view.prop(node, name) {
    Ok(VText(value)) -> value
    _ -> ""
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
    "editor" | "notebook" | "page" -> 320
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
    "editor" | "notebook" | "page" -> 200
    "form" | "window" -> 480
    _ -> 28
  }
}
