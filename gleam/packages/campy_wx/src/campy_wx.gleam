//// wx renderer for `campy_view` trees.
////
//// The process that calls `start` owns every wx object (wxErlang delivers
//// events to the owner), so there is no worker process and no command queue:
//// `mount`/`apply` are synchronous calls, and `next` is the single receive
//// point for wx events plus the caller's own messages.

import campy_view.{
  type Node, type Patch, type Value, Insert, Order, Remove, Replace, SetEvents,
  SetProps, VBool, VInt, VText,
}
import campy_wx/native
import campy_wx/plan
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Incoming {
  /// A declared view event: control id, event key, and the control's value.
  Event(id: String, key: String, value: Value)
  /// Any non-wx message addressed to the renderer's process.
  Message(message: Dynamic)
  /// Nothing happened before the timeout.
  Idle
  /// The top-level window asked to close.
  Closed
}

pub opaque type Shell {
  Shell(
    frame: Dynamic,
    frame_id: Int,
    widgets: Dict(String, Widget),
    by_wx: Dict(Int, String),
    next_wx: Int,
  )
}

type Widget {
  Widget(
    ref: Dynamic,
    kind: String,
    wx_id: Int,
    view_id: String,
    parent: Option(String),
    props: List(#(String, Value)),
    events: List(String),
    children: List(String),
    sizer: Option(Dynamic),
    layout: String,
    border: Int,
  )
}

pub fn start(title: String, width: Int, height: Int) -> Shell {
  let _ = native.new_app()

  let frame_id = 1000
  let frame = native.frame(frame_id, title, width, height)
  let sizer = native.box_sizer(True)
  native.set_sizer(frame, sizer)
  native.connect(frame, "window")

  let frame_widget =
    Widget(
      ref: frame,
      kind: "window",
      wx_id: frame_id,
      view_id: "__window__",
      parent: None,
      props: [],
      events: ["close"],
      children: [],
      sizer: Some(sizer),
      layout: "column",
      border: 0,
    )

  Shell(
    frame: frame,
    frame_id: frame_id,
    widgets: dict.from_list([#("__window__", frame_widget)]),
    by_wx: dict.from_list([#(frame_id, "__window__")]),
    next_wx: frame_id + 1,
  )
}

/// Mount a view. A `window`/`form` root configures and fills the frame; any
/// other root is added to the frame as its single expanding child.
pub fn mount(shell: Shell, root: Node) -> Result(Shell, String) {
  native.freeze(shell.frame)

  let result = case is_window(root.kind) {
    True -> mount_window(shell, root)
    False -> create_top(shell, root)
  }

  native.thaw(shell.frame)

  case result {
    Ok(shell) -> {
      native.layout(shell.frame)
      native.show(shell.frame)
      Ok(shell)
    }
    Error(error) -> Error(error)
  }
}

fn is_window(kind: String) -> Bool {
  case kind {
    "window" | "form" -> True
    _ -> False
  }
}

fn mount_window(shell: Shell, root: Node) -> Result(Shell, String) {
  let title = plan.text_of(root.props, "title") |> plan.unwrap_or("Campy")
  let width = plan.int_of(root.props, "w") |> plan.unwrap_or(640)
  let height = plan.int_of(root.props, "h") |> plan.unwrap_or(480)

  native.set_label(shell.frame, title)
  native.resize(shell.frame, width, height)

  let shell = rebind_frame(shell, root)

  let shell = case plan.layout(root) {
    plan.Row -> {
      let sizer = native.box_sizer(False)
      native.set_sizer(shell.frame, sizer)
      update_widget(shell, root.id, fn(widget) {
        Widget(..widget, sizer: Some(sizer), layout: "row")
      })
    }
    _ ->
      update_widget(shell, root.id, fn(widget) {
        Widget(..widget, layout: plan.layout_name(root))
      })
  }

  mount_children(shell, root.id, root.children)
}

fn rebind_frame(shell: Shell, root: Node) -> Shell {
  let frame_widget = case dict.get(shell.widgets, "__window__") {
    Ok(widget) -> widget
    Error(Nil) -> panic as "frame widget missing"
  }

  let widget =
    Widget(
      ..frame_widget,
      view_id: root.id,
      props: root.props,
      events: root.events,
      children: [],
    )

  Shell(
    ..shell,
    widgets: shell.widgets
      |> dict.delete("__window__")
      |> dict.insert(root.id, widget),
    by_wx: dict.insert(shell.by_wx, shell.frame_id, root.id),
  )
}

fn create_top(shell: Shell, root: Node) -> Result(Shell, String) {
  case create_node(shell, root, "__window__", 0) {
    Ok(#(shell, _widget)) -> Ok(shell)
    Error(error) -> Error(error)
  }
}

fn mount_children(
  shell: Shell,
  parent_id: String,
  children: List(Node),
) -> Result(Shell, String) {
  mount_children_loop(shell, parent_id, children, 0)
}

fn mount_children_loop(
  shell: Shell,
  parent_id: String,
  children: List(Node),
  index: Int,
) -> Result(Shell, String) {
  case children {
    [] -> Ok(shell)
    [child, ..rest] ->
      case create_node(shell, child, parent_id, index) {
        Ok(#(shell, _widget)) ->
          mount_children_loop(shell, parent_id, rest, index + 1)
        Error(error) -> Error(error)
      }
  }
}

fn create_node(
  shell: Shell,
  node: Node,
  parent_id: String,
  index: Int,
) -> Result(#(Shell, Widget), String) {
  use parent <- result.try(get_widget(shell, parent_id))

  let wx_id = shell.next_wx
  let kind = node.kind
  let text = plan.text_of(node.props, "text") |> plan.unwrap_or("")
  let value = plan.int_of(node.props, "value") |> plan.unwrap_or(0)
  let min = plan.int_of(node.props, "min") |> plan.unwrap_or(0)
  let max = plan.int_of(node.props, "max") |> plan.unwrap_or(100)
  let picture_path = plan.text_of(node.props, "picture") |> plan.unwrap_or(text)

  let created = case kind {
    "panel" | "group" -> Ok(native.panel(parent.ref, wx_id))
    "label" -> Ok(native.label(parent.ref, wx_id, text))
    "button" -> Ok(native.button(parent.ref, wx_id, text))
    "checkbox" -> Ok(native.checkbox(parent.ref, wx_id, text))
    "radio" -> Ok(native.radio(parent.ref, wx_id, text))
    "choice" -> Ok(native.choice(parent.ref, wx_id))
    "list" -> Ok(native.listbox(parent.ref, wx_id))
    "text" -> Ok(native.textctrl(parent.ref, wx_id, text))
    "memo" -> Ok(native.memo(parent.ref, wx_id, text))
    "slider" -> Ok(native.slider(parent.ref, wx_id, value, min, max))
    "progress" -> Ok(native.gauge(parent.ref, wx_id, max))
    "picture" -> Ok(native.picture(parent.ref, wx_id, picture_path))
    "window" | "form" -> Error("nested window is not supported")
    other -> Error("unknown widget kind: " <> other)
  }

  use ref <- result.try(created)
  native.connect(ref, kind)

  let widget =
    Widget(
      ref: ref,
      kind: kind,
      wx_id: wx_id,
      view_id: node.id,
      parent: Some(parent_id),
      props: node.props,
      events: node.events,
      children: [],
      sizer: None,
      layout: plan.layout_name(node),
      border: plan.border(node),
    )

  let shell = register(shell, widget)
  let shell = apply_all_props(shell, node.id)
  let shell = attach(shell, parent_id, node.id, index)

  let shell = case plan.layout(node), plan.is_container(kind) {
    plan.Column, True -> setup_sizer(shell, node.id, True)
    plan.Row, True -> setup_sizer(shell, node.id, False)
    _, _ -> shell
  }

  use shell <- result.try(mount_children(shell, node.id, node.children))
  Ok(#(shell, widget))
}

fn setup_sizer(shell: Shell, id: String, vertical: Bool) -> Shell {
  case get_widget(shell, id) {
    Error(_) -> shell
    Ok(widget) -> {
      let sizer = native.box_sizer(vertical)
      native.set_sizer(widget.ref, sizer)
      update_widget(shell, id, fn(widget) {
        Widget(..widget, sizer: Some(sizer), layout: case vertical {
          True -> "column"
          False -> "row"
        })
      })
    }
  }
}

fn attach(
  shell: Shell,
  parent_id: String,
  child_id: String,
  index: Int,
) -> Shell {
  case get_widget(shell, parent_id), get_widget(shell, child_id) {
    Ok(parent), Ok(child) -> {
      case parent.sizer {
        Some(sizer) ->
          native.insert(sizer, index, child.ref, parent.border, True)
        None -> native.raise(child.ref)
      }

      update_widget(shell, parent_id, fn(parent) {
        Widget(..parent, children: insert_at(parent.children, index, child_id))
      })
    }
    _, _ -> shell
  }
}

fn apply_all_props(shell: Shell, id: String) -> Shell {
  case get_widget(shell, id) {
    Error(_) -> shell
    Ok(widget) ->
      list.fold(
        list.map(widget.props, fn(prop) { prop.0 }),
        shell,
        fn(shell, name) { apply_prop(shell, id, name) },
      )
  }
}

fn apply_prop(shell: Shell, id: String, name: String) -> Shell {
  case get_widget(shell, id) {
    Error(_) -> shell
    Ok(widget) -> {
      case name {
        "title" -> {
          let title = plan.text_of(widget.props, "title") |> plan.unwrap_or("")
          native.set_label(widget.ref, title)
        }
        "text" -> apply_text(widget)
        "value" -> apply_value(widget)
        "checked" ->
          native.set_bool(
            widget.ref,
            widget.kind,
            plan.bool_of(widget.props, "checked") |> plan.unwrap_or(False),
          )
        "selection" ->
          native.set_selection(
            widget.ref,
            widget.kind,
            plan.int_of(widget.props, "selection") |> plan.unwrap_or(0),
          )
        "items" ->
          native.set_items(
            widget.ref,
            widget.kind,
            plan.items_of(widget.props, "items"),
          )
        "enabled" ->
          native.set_enabled(
            widget.ref,
            plan.bool_of(widget.props, "enabled") |> plan.unwrap_or(True),
          )
        "visible" ->
          native.set_visible(
            widget.ref,
            plan.bool_of(widget.props, "visible") |> plan.unwrap_or(True),
          )
        "x" | "y" | "w" | "h" -> apply_geometry(shell, widget)
        _ -> Nil
      }
      shell
    }
  }
}

fn apply_text(widget: Widget) -> Nil {
  let text = plan.text_of(widget.props, "text") |> plan.unwrap_or("")

  case widget.kind {
    "label" | "button" | "checkbox" | "radio" | "group" | "window" ->
      native.set_label(widget.ref, text)
    "text" | "memo" -> native.set_text(widget.ref, text)
    _ -> Nil
  }
}

fn apply_value(widget: Widget) -> Nil {
  case widget.kind {
    "slider" | "progress" ->
      native.set_int(
        widget.ref,
        widget.kind,
        plan.int_of(widget.props, "value") |> plan.unwrap_or(0),
      )
    "checkbox" | "radio" ->
      native.set_bool(
        widget.ref,
        widget.kind,
        plan.bool_of(widget.props, "value") |> plan.unwrap_or(False),
      )
    "choice" | "list" ->
      native.set_selection(
        widget.ref,
        widget.kind,
        plan.int_of(widget.props, "selection") |> plan.unwrap_or(0),
      )
    _ -> Nil
  }
}

fn apply_geometry(shell: Shell, widget: Widget) -> Nil {
  let x = plan.int_of(widget.props, "x") |> plan.unwrap_or(0)
  let y = plan.int_of(widget.props, "y") |> plan.unwrap_or(0)
  let width = plan.int_of(widget.props, "w") |> plan.unwrap_or(0)
  let height = plan.int_of(widget.props, "h") |> plan.unwrap_or(0)

  case geometry_applies(shell, widget) {
    True -> {
      native.move(widget.ref, x, y)
      native.resize(widget.ref, width, height)
    }
    False -> native.set_min_size(widget.ref, width, height)
  }
}

fn geometry_applies(shell: Shell, widget: Widget) -> Bool {
  case widget.parent {
    None -> True
    Some(parent_id) ->
      case get_widget(shell, parent_id) {
        Ok(parent) ->
          case parent.sizer {
            Some(_) -> False
            None -> True
          }
        Error(_) -> True
      }
  }
}

pub fn apply(shell: Shell, patches: List(Patch)) -> Result(Shell, String) {
  native.freeze(shell.frame)
  let result = list.try_fold(patches, shell, apply_patch)
  native.thaw(shell.frame)
  native.layout(shell.frame)
  result
}

fn apply_patch(shell: Shell, patch: Patch) -> Result(Shell, String) {
  case patch {
    SetProps(id, props) ->
      case get_widget(shell, id) {
        Error(_) -> Ok(shell)
        Ok(widget) -> {
          let changed = plan.changed_props(widget.props, props)
          let shell =
            update_widget(shell, id, fn(widget) {
              Widget(..widget, props: props)
            })
          Ok(
            list.fold(changed, shell, fn(shell, prop) {
              apply_prop(shell, id, prop.0)
            }),
          )
        }
      }
    SetEvents(id, events) ->
      Ok(
        update_widget(shell, id, fn(widget) { Widget(..widget, events: events) }),
      )
    Insert(parent_id, index, node) ->
      case create_node(shell, node, parent_id, index) {
        Ok(#(shell, _widget)) -> Ok(shell)
        Error(error) -> Error(error)
      }
    Remove(id) -> Ok(destroy_subtree(shell, id))
    Order(parent_id, ids) -> apply_order(shell, parent_id, ids)
    Replace(id, node) ->
      case get_widget(shell, id) {
        Error(error) -> Error(error)
        Ok(widget) -> {
          let parent_id = case widget.parent {
            Some(parent_id) -> parent_id
            None -> "__window__"
          }
          let index = case get_widget(shell, parent_id) {
            Ok(parent) -> index_of(parent.children, id)
            Error(_) -> 0
          }
          let shell = destroy_subtree(shell, id)
          case create_node(shell, node, parent_id, index) {
            Ok(#(shell, _widget)) -> Ok(shell)
            Error(error) -> Error(error)
          }
        }
      }
  }
}

fn apply_order(
  shell: Shell,
  parent_id: String,
  ids: List(String),
) -> Result(Shell, String) {
  use parent <- result.try(get_widget(shell, parent_id))
  let shell =
    update_widget(shell, parent_id, fn(widget) {
      Widget(..widget, children: ids)
    })

  case parent.sizer {
    Some(sizer) -> {
      list.each(parent.children, fn(id) {
        case get_widget(shell, id) {
          Ok(child) -> native.detach(sizer, child.ref)
          Error(_) -> Nil
        }
      })
      list.index_map(ids, fn(id, index) {
        case get_widget(shell, id) {
          Ok(child) ->
            native.insert(sizer, index, child.ref, parent.border, True)
          Error(_) -> Nil
        }
      })
      Nil
    }
    None ->
      list.each(ids, fn(id) {
        case get_widget(shell, id) {
          Ok(child) -> native.raise(child.ref)
          Error(_) -> Nil
        }
      })
  }

  Ok(shell)
}

fn destroy_subtree(shell: Shell, id: String) -> Shell {
  case get_widget(shell, id) {
    Error(_) -> shell
    Ok(widget) -> {
      case widget.parent {
        Some(parent_id) ->
          case get_widget(shell, parent_id) {
            Ok(parent) ->
              case parent.sizer {
                Some(sizer) -> native.detach(sizer, widget.ref)
                None -> Nil
              }
            Error(_) -> Nil
          }
        None -> Nil
      }

      let shell = remove_subtree_registry(shell, id)
      native.destroy(widget.ref)

      case widget.parent {
        Some(parent_id) ->
          update_widget(shell, parent_id, fn(parent) {
            Widget(
              ..parent,
              children: list.filter(parent.children, fn(child) { child != id }),
            )
          })
        None -> shell
      }
    }
  }
}

fn remove_subtree_registry(shell: Shell, id: String) -> Shell {
  case get_widget(shell, id) {
    Error(_) -> shell
    Ok(widget) -> {
      let shell = list.fold(widget.children, shell, remove_subtree_registry)
      Shell(
        ..shell,
        widgets: dict.delete(shell.widgets, id),
        by_wx: dict.delete(shell.by_wx, widget.wx_id),
      )
    }
  }
}

/// The single receive point: wx events are normalised and mapped to declared
/// view events; every other message is handed back untouched.
pub fn next(shell: Shell, timeout_ms: Int) -> Incoming {
  case native.next_message(timeout_ms) {
    native.WxEvent(wx_id, "close") if wx_id == shell.frame_id -> Closed
    native.WxEvent(wx_id, "command") -> command_event(shell, wx_id)
    native.WxEvent(_wx_id, _event_type) -> Idle
    native.Other(message) -> Message(message)
    native.Idle -> Idle
  }
}

fn command_event(shell: Shell, wx_id: Int) -> Incoming {
  case dict.get(shell.by_wx, wx_id) {
    Error(Nil) -> Idle
    Ok(view_id) ->
      case dict.get(shell.widgets, view_id) {
        Error(Nil) -> Idle
        Ok(widget) -> {
          let key = plan.event_key(widget.kind)
          case list.contains(widget.events, key) {
            False -> Idle
            True -> Event(widget.view_id, key, event_value(widget))
          }
        }
      }
  }
}

fn event_value(widget: Widget) -> Value {
  case widget.kind {
    "text" | "memo" -> VText(native.get_text(widget.ref))
    "checkbox" | "radio" -> VBool(native.get_bool(widget.ref, widget.kind))
    "choice" | "list" -> VInt(native.get_selection(widget.ref, widget.kind))
    "slider" -> VInt(native.get_int(widget.ref, widget.kind))
    "progress" -> VInt(native.get_int(widget.ref, widget.kind))
    _ -> VBool(True)
  }
}

pub fn focus(shell: Shell, id: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.focus(widget.ref)
    Error(_) -> Nil
  }
}

pub fn close(shell: Shell) -> Nil {
  native.destroy(shell.frame)
  native.destroy_app()
}

pub fn now_ms() -> Int {
  native.now_ms()
}

pub fn getenv(name: String) -> String {
  native.getenv(name)
}

fn get_widget(shell: Shell, id: String) -> Result(Widget, String) {
  case dict.get(shell.widgets, id) {
    Ok(widget) -> Ok(widget)
    Error(Nil) -> Error("no such widget: " <> id)
  }
}

fn update_widget(
  shell: Shell,
  id: String,
  change: fn(Widget) -> Widget,
) -> Shell {
  case dict.get(shell.widgets, id) {
    Ok(widget) ->
      Shell(..shell, widgets: dict.insert(shell.widgets, id, change(widget)))
    Error(Nil) -> shell
  }
}

fn register(shell: Shell, widget: Widget) -> Shell {
  Shell(
    ..shell,
    widgets: dict.insert(shell.widgets, widget.view_id, widget),
    by_wx: dict.insert(shell.by_wx, widget.wx_id, widget.view_id),
    next_wx: int.max(shell.next_wx, widget.wx_id + 1),
  )
}

fn insert_at(items: List(a), index: Int, item: a) -> List(a) {
  let #(before, after) = list.split(items, index)
  list.append(before, list.append([item], after))
}

fn index_of(items: List(String), id: String) -> Int {
  index_of_loop(items, id, 0)
}

fn index_of_loop(items: List(String), id: String, index: Int) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case first == id {
        True -> index
        False -> index_of_loop(rest, id, index + 1)
      }
  }
}
