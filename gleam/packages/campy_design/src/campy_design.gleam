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

import campy_catalog
import campy_view.{type Node, type Value, VBool, VInt, VText}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

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
      // The form's recorded position positions it in the form editor only;
      // the runtime resizes by w/h and ignores x/y (the run window clears
      // them before resolving the published view).
      x: int_prop(root, "x", 0),
      y: int_prop(root, "y", 0),
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
  // LCL-style docking in a free container: top/bottom/left/right children
  // reserve bands in document order (each side stacks), then fill/client
  // children take whatever remains — in document order, overlapping each
  // other when there are several. Free-positioned children keep raw x/y/w/h.
  let #(acc, remaining) = dock_edges(children, parent_id, acc, inner)

  children
  |> list.filter(fn(child) {
    case text_prop(child, "align") {
      "client" | "fill" -> True
      _ -> False
    }
  })
  |> list.fold(acc, fn(acc, child) {
    add_child(child, remaining, parent_id, acc)
  })
}

fn dock_edges(
  children: List(Node),
  parent_id: String,
  acc: List(Placed),
  remaining: Rect,
) -> #(List(Placed), Rect) {
  case children {
    [] -> #(acc, remaining)
    [child, ..rest] -> {
      let width = int_prop(child, "w", default_w(child.kind))
      let height = int_prop(child, "h", default_h(child.kind))

      case text_prop(child, "align") {
        "top" -> {
          let h = int.min(height, remaining.h)
          dock_edges(
            rest,
            parent_id,
            add_child(
              child,
              Rect(x: remaining.x, y: remaining.y, w: remaining.w, h: h),
              parent_id,
              acc,
            ),
            Rect(
              x: remaining.x,
              y: remaining.y + h,
              w: remaining.w,
              h: remaining.h - h,
            ),
          )
        }
        "bottom" -> {
          let h = int.min(height, remaining.h)
          dock_edges(
            rest,
            parent_id,
            add_child(
              child,
              Rect(
                x: remaining.x,
                y: remaining.y + remaining.h - h,
                w: remaining.w,
                h: h,
              ),
              parent_id,
              acc,
            ),
            Rect(
              x: remaining.x,
              y: remaining.y,
              w: remaining.w,
              h: remaining.h - h,
            ),
          )
        }
        "left" -> {
          let w = int.min(width, remaining.w)
          dock_edges(
            rest,
            parent_id,
            add_child(
              child,
              Rect(x: remaining.x, y: remaining.y, w: w, h: remaining.h),
              parent_id,
              acc,
            ),
            Rect(
              x: remaining.x + w,
              y: remaining.y,
              w: remaining.w - w,
              h: remaining.h,
            ),
          )
        }
        "right" -> {
          let w = int.min(width, remaining.w)
          dock_edges(
            rest,
            parent_id,
            add_child(
              child,
              Rect(
                x: remaining.x + remaining.w - w,
                y: remaining.y,
                w: w,
                h: remaining.h,
              ),
              parent_id,
              acc,
            ),
            Rect(
              x: remaining.x,
              y: remaining.y,
              w: remaining.w - w,
              h: remaining.h,
            ),
          )
        }
        "client" | "fill" -> dock_edges(rest, parent_id, acc, remaining)
        _ -> {
          let x = int_prop(child, "x", 0)
          let y = int_prop(child, "y", 0)
          dock_edges(
            rest,
            parent_id,
            add_child(
              child,
              Rect(x: remaining.x + x, y: remaining.y + y, w: width, h: height),
              parent_id,
              acc,
            ),
            remaining,
          )
        }
      }
    }
  }
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

/// Set or replace a single node property. Geometry edits should prefer
/// `set_rect`/`set_absolute_rect` so sizes clamp and alignment clears.
pub fn set_prop(node: Node, name: String, value: Value) -> Node {
  let props = list.filter(node.props, fn(prop) { prop.0 != name })
  campy_view.with_props(node, list.append(props, [#(name, value)]))
}

/// Set one property on a control found by id. Unknown ids leave the tree
/// unchanged, which keeps callers from having to check first.
pub fn set_node_prop(
  root: Node,
  id: String,
  name: String,
  value: Value,
) -> Node {
  update_node(root, id, fn(node) { set_prop(node, name, value) })
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
  campy_catalog.default_w(kind)
}

pub fn default_h(kind: String) -> Int {
  campy_catalog.default_h(kind)
}

/// Resolve a form into a design-mode view: geometry becomes explicit absolute
/// coordinates (relative to the immediate parent), every container uses free
/// layout, and every node declares the `select` event. The root becomes a
/// `canvas` node.
pub fn design_view(root: Node, canvas_id: String) -> Node {
  let layout = resolve(root)
  let places =
    dict.from_list(list.map(layout.places, fn(placed) { #(placed.id, placed) }))

  let root_rect = case dict.get(places, root.id) {
    Ok(placed) -> placed.rect
    Error(Nil) -> Rect(0, 0, 640, 480)
  }

  build_design(root, Rect(0, 0, 0, 0), root_rect, places, canvas_id, True)
}

fn build_design(
  node: Node,
  parent_rect: Rect,
  own_rect: Rect,
  places: dict.Dict(String, Placed),
  canvas_id: String,
  is_root: Bool,
) -> Node {
  let rect = case dict.get(places, node.id) {
    Ok(placed) -> placed.rect
    Error(Nil) -> own_rect
  }

  let props =
    node.props
    |> list.filter(fn(prop) { prop.0 != "border" && prop.0 != "gap" })
    |> upsert("x", VInt(rect.x - parent_rect.x))
    |> upsert("y", VInt(rect.y - parent_rect.y))
    |> upsert("w", VInt(rect.w))
    |> upsert("h", VInt(rect.h))
    |> upsert("layout", VText("free"))
    |> upsert("design", VBool(True))

  let children =
    list.map(node.children, fn(child) {
      build_design(
        child,
        case is_root {
          // The canvas spans the whole design surface: the root's direct
          // children keep canvas-absolute positions (the form outline is
          // painted chrome at the form's editor position on the canvas).
          True -> Rect(0, 0, 0, 0)
          False -> rect
        },
        rect,
        places,
        canvas_id,
        False,
      )
    })

  campy_view.Node(
    kind: case is_root {
      True -> "canvas"
      False -> node.kind
    },
    id: case is_root {
      True -> canvas_id
      False -> node.id
    },
    key: node.key,
    props: props,
    events: ["select"],
    children: children,
    extra: node.extra,
  )
}

fn upsert(
  props: List(#(String, Value)),
  name: String,
  value: Value,
) -> List(#(String, Value)) {
  list.append(list.filter(props, fn(prop) { prop.0 != name }), [#(name, value)])
}

/// Find a placed rectangle by control id.
pub fn placed(layout: Layout, id: String) -> Option(Placed) {
  case list.find(layout.places, fn(placed) { placed.id == id }) {
    Ok(placed) -> Some(placed)
    Error(Nil) -> None
  }
}

/// Find a node by control id.
pub fn find_node(root: Node, id: String) -> Option(Node) {
  case root.id == id {
    True -> Some(root)
    False ->
      case
        list.find(root.children, fn(child) { find_node(child, id) != None })
      {
        Ok(child) -> find_node(child, id)
        Error(Nil) -> None
      }
  }
}

/// Materialize the resolved layout into the document: every node gets explicit
/// x/y/w/h relative to its parent and every container becomes free-layout.
/// Called before a geometry edit so column/row forms cannot snap the edit back.
pub fn freeze(root: Node) -> Node {
  let layout = resolve(root)
  let places =
    dict.from_list(list.map(layout.places, fn(placed) { #(placed.id, placed) }))

  freeze_node(root, Rect(0, 0, 0, 0), places)
}

fn freeze_node(
  node: Node,
  parent_rect: Rect,
  places: dict.Dict(String, Placed),
) -> Node {
  let rect = case dict.get(places, node.id) {
    Ok(placed) -> placed.rect
    Error(Nil) -> Rect(0, 0, default_w(node.kind), default_h(node.kind))
  }

  let props =
    node.props
    |> list.filter(fn(prop) { prop.0 != "border" && prop.0 != "gap" })
    |> upsert("x", VInt(rect.x - parent_rect.x))
    |> upsert("y", VInt(rect.y - parent_rect.y))
    |> upsert("w", VInt(rect.w))
    |> upsert("h", VInt(rect.h))
    |> upsert("layout", VText("free"))

  campy_view.Node(
    kind: node.kind,
    id: node.id,
    key: node.key,
    props: props,
    events: node.events,
    children: list.map(node.children, fn(child) {
      freeze_node(child, rect, places)
    }),
    extra: node.extra,
  )
}

/// Every non-root control whose rectangle intersects the given rectangle.
pub fn intersecting(layout: Layout, rect: Rect) -> List(String) {
  layout.places
  |> list.filter(fn(placed) {
    placed.id != layout.root && intersects(placed.rect, rect)
  })
  |> list.map(fn(placed) { placed.id })
}

pub fn intersects(a: Rect, b: Rect) -> Bool {
  a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

/// The absolute rectangle of a control in the resolved form.
pub fn absolute(root: Node, id: String) -> Option(Rect) {
  case placed(resolve(root), id) {
    Some(found) -> Some(found.rect)
    None -> None
  }
}

/// Set a rectangle expressed in canvas (absolute) coordinates. Documents store
/// parent-relative coordinates, so the parent's resolved origin is subtracted.
/// Call `freeze` first when the parent still uses a sizer.
pub fn set_absolute_rect(root: Node, id: String, rect: Rect) -> Node {
  let layout = resolve(root)

  case placed(layout, id) {
    None -> root
    Some(target) -> {
      let origin = case target.parent {
        Some(parent_id) ->
          case placed(layout, parent_id) {
            Some(parent) -> parent.rect
            None -> Rect(0, 0, 0, 0)
          }
        None -> Rect(0, 0, 0, 0)
      }

      set_rect(
        root,
        id,
        Rect(x: rect.x - origin.x, y: rect.y - origin.y, w: rect.w, h: rect.h),
      )
    }
  }
}

/// The origin of a control's parent in canvas coordinates. Native renderers
/// need this to convert absolute artwork rectangles into child coordinates.
pub fn parent_origin(root: Node, id: String) -> #(Int, Int) {
  parent_origin_in(resolve(root), id)
}

pub fn parent_origin_in(layout: Layout, id: String) -> #(Int, Int) {
  case placed(layout, id) {
    Some(target) ->
      case target.parent {
        Some(parent_id) ->
          case placed(layout, parent_id) {
            Some(parent) -> #(parent.rect.x, parent.rect.y)
            None -> #(0, 0)
          }
        None -> #(0, 0)
      }
    None -> #(0, 0)
  }
}

pub fn insert_child(
  root: Node,
  parent_id: String,
  index: Int,
  child: Node,
) -> Result(Node, String) {
  case insert_into(root, parent_id, index, child) {
    Ok(node) -> Ok(node)
    Error(Nil) -> Error("no such container: " <> parent_id)
  }
}

fn insert_into(
  node: Node,
  parent_id: String,
  index: Int,
  child: Node,
) -> Result(Node, Nil) {
  case node.id == parent_id {
    True ->
      Ok(campy_view.with_children(node, insert_at(node.children, index, child)))
    False -> {
      let #(children, found) =
        list.fold(node.children, #([], False), fn(acc, candidate) {
          let #(kept, found) = acc

          case found {
            True -> #(list.append(kept, [candidate]), True)
            False ->
              case insert_into(candidate, parent_id, index, child) {
                Ok(updated) -> #(list.append(kept, [updated]), True)
                Error(Nil) -> #(list.append(kept, [candidate]), False)
              }
          }
        })

      case found {
        True -> Ok(campy_view.with_children(node, children))
        False -> Error(Nil)
      }
    }
  }
}

/// Remove a subtree, returning the new root and the removed node.
pub fn remove_node(root: Node, id: String) -> Result(#(Node, Node), String) {
  case remove_from(root, id) {
    Ok(found) -> Ok(found)
    Error(Nil) -> Error("no such control: " <> id)
  }
}

fn remove_from(node: Node, id: String) -> Result(#(Node, Node), Nil) {
  case remove_direct(node.children, id) {
    Ok(#(children, removed)) ->
      Ok(#(campy_view.with_children(node, children), removed))
    Error(Nil) -> {
      let #(children, removed) =
        list.fold(node.children, #([], None), fn(acc, candidate) {
          let #(kept, removed) = acc

          case removed {
            Some(_) -> #(list.append(kept, [candidate]), removed)
            None ->
              case remove_from(candidate, id) {
                Ok(#(updated, found)) -> #(
                  list.append(kept, [updated]),
                  Some(found),
                )
                Error(Nil) -> #(list.append(kept, [candidate]), None)
              }
          }
        })

      case removed {
        Some(found) -> Ok(#(campy_view.with_children(node, children), found))
        None -> Error(Nil)
      }
    }
  }
}

fn remove_direct(
  children: List(Node),
  id: String,
) -> Result(#(List(Node), Node), Nil) {
  case children {
    [] -> Error(Nil)
    [first, ..rest] ->
      case first.id == id {
        True -> Ok(#(rest, first))
        False ->
          case remove_direct(rest, id) {
            Ok(#(kept, removed)) -> Ok(#([first, ..kept], removed))
            Error(Nil) -> Error(Nil)
          }
      }
  }
}

pub fn parent_of(root: Node, id: String) -> Option(String) {
  parent_loop(root, id)
}

fn parent_loop(node: Node, id: String) -> Option(String) {
  case list.any(node.children, fn(child) { child.id == id }) {
    True -> Some(node.id)
    False ->
      first_some(list.map(node.children, fn(child) { parent_loop(child, id) }))
  }
}

fn first_some(items: List(Option(a))) -> Option(a) {
  case items {
    [] -> None
    [Some(value), ..] -> Some(value)
    [None, ..rest] -> first_some(rest)
  }
}

pub fn child_count(root: Node, parent_id: String) -> Int {
  case find_node(root, parent_id) {
    Some(parent) -> list.length(parent.children)
    None -> 0
  }
}

pub fn index_of(
  root: Node,
  parent_id: String,
  id: String,
) -> Result(Int, String) {
  case find_node(root, parent_id) {
    None -> Error("no such container: " <> parent_id)
    Some(parent) -> index_in(parent.children, id, 0)
  }
}

fn index_in(
  children: List(Node),
  id: String,
  index: Int,
) -> Result(Int, String) {
  case children {
    [] -> Error("no such control: " <> id)
    [first, ..rest] ->
      case first.id == id {
        True -> Ok(index)
        False -> index_in(rest, id, index + 1)
      }
  }
}

/// Whether `id` is the ancestor itself or lives inside its subtree.
pub fn is_within(root: Node, ancestor_id: String, id: String) -> Bool {
  case find_node(root, ancestor_id) {
    Some(ancestor) -> find_node(ancestor, id) != None
    None -> False
  }
}

/// Move a control to another container, keeping its document properties. The
/// caller re-applies absolute geometry afterwards when a visual position
/// matters.
pub fn reparent(
  root: Node,
  id: String,
  new_parent: String,
) -> Result(Node, String) {
  case parent_of(root, id) {
    None -> Error("no such control: " <> id)
    Some(current) if current == new_parent -> Ok(root)
    _ ->
      case is_within(root, id, new_parent) {
        True -> Error("cannot move a control into itself")
        False -> {
          use #(updated, removed) <- result.try(remove_node(root, id))
          insert_child(
            updated,
            new_parent,
            child_count(updated, new_parent),
            removed,
          )
        }
      }
  }
}

pub fn reorder(root: Node, id: String, index: Int) -> Result(Node, String) {
  case parent_of(root, id) {
    None -> Error("no such control: " <> id)
    Some(parent) -> {
      use #(updated, removed) <- result.try(remove_node(root, id))
      insert_child(updated, parent, index, removed)
    }
  }
}

pub fn bring_to_front(root: Node, id: String) -> Result(Node, String) {
  case parent_of(root, id) {
    None -> Error("no such control: " <> id)
    Some(parent) -> {
      use #(updated, removed) <- result.try(remove_node(root, id))
      insert_child(updated, parent, child_count(updated, parent), removed)
    }
  }
}

pub fn send_to_back(root: Node, id: String) -> Result(Node, String) {
  case parent_of(root, id) {
    None -> Error("no such control: " <> id)
    Some(parent) -> {
      use #(updated, removed) <- result.try(remove_node(root, id))
      insert_child(updated, parent, 0, removed)
    }
  }
}

/// The deepest container under the point that may adopt a drop. When `moving`
/// is set, that control and its descendants are excluded, so a container can
/// never adopt itself.
pub fn container_for_drop(
  root: Node,
  layout: Layout,
  x: Int,
  y: Int,
  moving: Option(String),
) -> Option(Placed) {
  let candidates =
    list.filter(layout.places, fn(candidate) {
      candidate.container
      && contains(candidate.rect, x, y)
      && !inside_moving(root, candidate.id, moving)
    })

  find_last(candidates, fn(_) { True })
}

fn inside_moving(
  root: Node,
  candidate: String,
  moving: Option(String),
) -> Bool {
  case moving {
    None -> False
    Some(id) -> is_within(root, id, candidate)
  }
}

fn insert_at(items: List(a), index: Int, item: a) -> List(a) {
  let #(before, after) = list.split(items, int.max(0, index))
  list.append(before, [item, ..after])
}
