//// Target-neutral declarative view tree.
////
//// A view is plain data: a tree of nodes with a string kind, a stable id, an
//// optional reconciliation key, property values, declared events, and
//// children. One description drives the designer, the running app, and any
//// later renderer (HTML, a plugin panel); `campy_view/diff` turns one tree
//// into a patch list.
////
//// The same shape is used for persistence and transport (ADR 0004, ADR 0005).
//// Keep it serializable: no functions, no handles, no renderer objects.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Value {
  VText(String)
  VBool(Bool)
  VInt(Int)
  VFloat(Float)
  VList(List(Value))
  VMap(List(#(String, Value)))
  /// JSON null. Renderers treat it as unset; it exists so unknown future
  /// fields survive a document round trip.
  VNull
}

pub type Node {
  Node(
    kind: String,
    id: String,
    key: Option(String),
    props: List(#(String, Value)),
    events: List(String),
    children: List(Node),
    /// Document fields this version does not understand, preserved verbatim so
    /// an older IDE cannot destroy newer data. Never used for rendering.
    extra: List(#(String, Value)),
  )
}

pub type Document {
  Document(schema: Int, view: Node, extra: List(#(String, Value)))
}

pub type Patch {
  /// Replace the node's property set with this complete, authoritative set.
  /// Renderers apply only values that differ from their current state.
  SetProps(id: String, props: List(#(String, Value)))
  /// Replace the node's declared events with this complete set.
  SetEvents(id: String, events: List(String))
  /// Mount a new subtree under `parent` at `index`. The index is relative to
  /// the parent's children after the preceding removals and replacements in
  /// the same batch have been applied.
  Insert(parent: String, index: Int, node: Node)
  /// Unmount a subtree. Descendants never receive their own patches.
  Remove(id: String)
  /// Authoritative child order for `parent`: list order and z-order are the
  /// same sequence. Always safe to apply, even when order did not change.
  Order(parent: String, ids: List(String))
  /// Swap a node's kind or identity. Renderers remount the subtree in place at
  /// `id`, then honor a following `Order`.
  Replace(id: String, node: Node)
}

pub fn node(kind: String, id: String) -> Node {
  Node(
    kind: kind,
    id: id,
    key: None,
    props: [],
    events: [],
    children: [],
    extra: [],
  )
}

pub fn with_key(node: Node, key: String) -> Node {
  Node(..node, key: Some(key))
}

pub fn with_props(node: Node, props: List(#(String, Value))) -> Node {
  Node(..node, props: props)
}

pub fn with_events(node: Node, events: List(String)) -> Node {
  Node(..node, events: events)
}

pub fn with_children(node: Node, children: List(Node)) -> Node {
  Node(..node, children: children)
}

pub fn with_child(node: Node, child: Node) -> Node {
  Node(..node, children: list.append(node.children, [child]))
}

pub fn with_extra(node: Node, extra: List(#(String, Value))) -> Node {
  Node(..node, extra: extra)
}

pub fn prop(node: Node, name: String) -> Result(Value, Nil) {
  node.props
  |> dict.from_list
  |> dict.get(name)
}

/// Stable identity for reconciliation: the explicit key when present,
/// otherwise the id. Sibling identities must be unique (see `validate`).
pub fn identity(node: Node) -> String {
  case node.key {
    Some(key) -> key
    None -> node.id
  }
}

/// Deterministic shape: props sorted by name (last duplicate wins), events
/// deduplicated in first-seen order, children in semantic order, and extra
/// document fields sorted with reserved field names dropped. `diff` and the
/// canonical JSON writer both normalize, so equal documents compare equal.
pub fn normalize(node: Node) -> Node {
  Node(
    ..node,
    props: sort_fields(node.props, []),
    events: list.unique(node.events),
    children: list.map(node.children, normalize),
    extra: sort_fields(node.extra, reserved_fields()),
  )
}

/// Field names owned by the view format; `extra` may not shadow them.
pub fn reserved_fields() -> List(String) {
  ["kind", "id", "key", "props", "events", "children"]
}

fn sort_fields(
  fields: List(#(String, Value)),
  reserved: List(String),
) -> List(#(String, Value)) {
  fields
  |> list.filter(fn(field) { !list.contains(reserved, field.0) })
  |> dict.from_list
  |> dict.to_list
  |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
}

/// Every node id in pre-order.
pub fn ids(node: Node) -> List(String) {
  [node.id, ..list.flatten(list.map(node.children, ids))]
}

/// Structural validation: non-empty kind and id, globally unique ids, unique
/// sibling identities, no empty keys. Property names and values are checked by
/// the widget catalog, not here.
pub fn validate(root: Node) -> Result(Nil, String) {
  use _ <- result.try(check_node(root))
  case first_duplicate(ids(root)) {
    Some(duplicate) -> Error("duplicate node id: " <> duplicate)
    None -> Ok(Nil)
  }
}

fn check_node(node: Node) -> Result(Nil, String) {
  case node.kind, node.id {
    "", _ -> Error("node kind must not be empty")
    _, "" -> Error("node id must not be empty")
    _, _ ->
      case node.key {
        Some("") -> Error("node key must not be empty: " <> node.id)
        _ -> check_children(node.children)
      }
  }
}

fn check_children(children: List(Node)) -> Result(Nil, String) {
  case first_duplicate(list.map(children, identity)) {
    Some(duplicate) -> Error("duplicate sibling key or id: " <> duplicate)
    None ->
      list.fold(children, Ok(Nil), fn(acc, child) {
        case acc {
          Error(error) -> Error(error)
          Ok(Nil) -> check_node(child)
        }
      })
  }
}

fn first_duplicate(items: List(String)) -> Option(String) {
  first_duplicate_loop(items, dict.new())
}

fn first_duplicate_loop(
  items: List(String),
  seen: Dict(String, Nil),
) -> Option(String) {
  case items {
    [] -> None
    [first, ..rest] ->
      case dict.has_key(seen, first) {
        True -> Some(first)
        False -> first_duplicate_loop(rest, dict.insert(seen, first, Nil))
      }
  }
}
