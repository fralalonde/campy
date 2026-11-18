//// wx renderer for `campy_view` trees.
////
//// The process that calls `start` owns every wx object (wxErlang delivers
//// events to the owner), so there is no worker process and no command queue:
//// `mount`/`apply` are synchronous calls, and `next` is the single receive
//// point for wx events plus the caller's own messages.

import campy_catalog
import campy_design
import campy_view.{
  type Node, type Patch, type Value, Insert, Order, Remove, Replace, SetEvents,
  SetProps, VBool, VInt, VMap, VText,
}
import campy_view/diff
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
  /// A declared view event from the run window (the attached app's UI).
  RunEvent(id: String, key: String, value: Value)
  /// A non-wx message addressed to the renderer's process.
  Message(message: Dynamic)
  /// An editor's jump list picked an entry ("name:line").
  Jumped(view_id: String, text: String)
  /// Nothing happened before the timeout.
  Idle
  /// The top-level window asked to close.
  Closed
  /// The run window asked to close (the user closed the app's window).
  RunClosed
  /// A canvas needs painting; the caller should call `paint`.
  Paint(id: String)
  /// Mouse input on a selection handle: role 0..7 resize, 8 move.
  /// A left click on a design widget; coordinates are relative to that widget.
  Mouse(id: String, kind: String, x: Int, y: Int, control: Bool)
  /// A frame-level shortcut key from char_hook.
  KeyPressed(Key)
  /// A frame accelerator; works even while a grid cell editor has focus.
  Accelerator(action: String)
  /// The frame moved or resized; screen-anchored selection chrome must be
  /// repositioned.
  FrameMoved
}

pub type Key {
  Key(code: String, control: Bool, shift: Bool, alt: Bool)
}

pub opaque type Shell {
  Shell(
    frame: Dynamic,
    frame_id: Int,
    widgets: Dict(String, Widget),
    by_wx: Dict(Int, String),
    next_wx: Int,
    chrome: Chrome,
    /// The running app's own window, when one is open. Separate registries
    /// with a disjoint wx-id space (frames at 900000+), so the single message
    /// pump can attribute every wx event to the right window.
    run: Option(RunWindow),
  )
}

/// The running app's top-level window and its widget registries. Opaque:
/// only this module reads or drives it.
pub opaque type RunWindow {
  RunWindow(
    frame: Dynamic,
    frame_id: Int,
    widgets: Dict(String, Widget),
    by_wx: Dict(Int, String),
    next_wx: Int,
    root: Node,
  )
}

/// Selection and marquee chrome. Selection is native grab panels (see
/// `show_selection`); the canvas paint only draws the marquee.
pub type Chrome {
  Chrome(marquee: Option(#(Int, Int, Int, Int)))
}

fn empty_chrome() -> Chrome {
  Chrome(marquee: None)
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
    grow: Bool,
  )
}

pub fn start(title: String, width: Int, height: Int) -> Shell {
  let _ = native.new_app()
  shell_with_frame(title, width, height, 1000)
}

/// A second top-level window in the same wx app (no `wx:new`): the run
/// window. Its id space starts high, away from the main shell's ids, so the
/// shared message pump can tell the two apart.
fn shell_with_frame(
  title: String,
  width: Int,
  height: Int,
  frame_id: Int,
) -> Shell {
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
      grow: True,
    )

  Shell(
    frame: frame,
    frame_id: frame_id,
    widgets: dict.from_list([#("__window__", frame_widget)]),
    by_wx: dict.from_list([#(frame_id, "__window__")]),
    next_wx: frame_id + 1,
    chrome: empty_chrome(),
    run: None,
  )
}

// ---------------------------------------------------------------------------
// The run window: the attached app's live view in its own top-level window.
// ---------------------------------------------------------------------------

/// Open the run window and mount the app's published view into it. The view
/// root may be a `form`/`window` node: it configures the window like a form.
pub fn open_run_window(
  shell: Shell,
  title: String,
  root: Node,
) -> Result(Shell, String) {
  let width = plan.int_of(root.props, "w") |> plan.unwrap_or(640)
  let height = plan.int_of(root.props, "h") |> plan.unwrap_or(480)
  let root = case plan.text_of(root.props, "title") {
    Ok(_) -> root
    Error(_) ->
      campy_view.with_props(root, [#("title", VText(title)), ..root.props])
  }
  let child = shell_with_frame(title, width, height, 900_000)

  case mount(child, root) {
    Ok(mounted) ->
      Ok(
        Shell(
          ..shell,
          run: Some(RunWindow(
            frame: mounted.frame,
            frame_id: mounted.frame_id,
            widgets: mounted.widgets,
            by_wx: mounted.by_wx,
            next_wx: mounted.next_wx,
            root: root,
          )),
        ),
      )
    Error(error) -> {
      native.destroy(child.frame)
      Error(error)
    }
  }
}

/// Push a new published view into the open run window (structural diff).
pub fn update_run(shell: Shell, root: Node) -> Shell {
  case shell.run {
    None -> shell
    Some(run) ->
      case apply(run_as_shell(run), diff.diff(run.root, root)) {
        Ok(updated) ->
          Shell(
            ..shell,
            run: Some(
              RunWindow(
                ..run,
                widgets: updated.widgets,
                by_wx: updated.by_wx,
                next_wx: updated.next_wx,
                root: root,
              ),
            ),
          )
        Error(_) -> shell
      }
  }
}

/// Close the run window (the app was stopped or the window asked to close).
pub fn close_run(shell: Shell) -> Shell {
  case shell.run {
    None -> shell
    Some(run) -> {
      native.destroy(run.frame)
      Shell(..shell, run: None)
    }
  }
}

/// True when the run window is open.
pub fn run_open(shell: Shell) -> Bool {
  case shell.run {
    Some(_) -> True
    None -> False
  }
}

/// Resize the main frame and re-run the align pass (same path a user
/// maximize takes). Probe and tool support.
pub fn resize_frame(shell: Shell, width: Int, height: Int) -> Nil {
  native.resize(shell.frame, width, height)
  native.layout(shell.frame)
  relayout_free_children(shell)
}

/// A layout child's current widget rectangle: #(x, y, w, h).
pub fn widget_rect(
  shell: Shell,
  id: String,
) -> Result(#(Int, Int, Int, Int), Nil) {
  let from = fn(widgets: Dict(String, Widget)) {
    case dict.get(widgets, id) {
      Ok(widget) ->
        case native.widget_rect(widget.ref) {
          Ok(#(x, y, w, h)) -> Ok(#(x, y, w, h))
          Error(_) -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  }
  case from(shell.widgets) {
    Ok(rect) -> Ok(rect)
    Error(_) ->
      case shell.run {
        Some(run) -> from(run.widgets)
        None -> Error(Nil)
      }
  }
}

/// Re-wrap a run window's registries as a Shell so the mount/apply machinery
/// can drive it; never stored back as the main shell.
fn run_as_shell(run: RunWindow) -> Shell {
  Shell(
    frame: run.frame,
    frame_id: run.frame_id,
    widgets: run.widgets,
    by_wx: run.by_wx,
    next_wx: run.next_wx,
    chrome: empty_chrome(),
    run: None,
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
      relayout_free_children(shell)
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
    "menubar" -> Ok(native.menubar())
    "menu" -> Ok(native.menu())
    "menuitem" -> Ok(native.menuitem(parent.ref, wx_id, text))
    "toolbar" -> Ok(native.toolbar(shell.frame))
    "tool" ->
      Ok(native.tool_icon(parent.ref, wx_id, text, tool_icon_kind(node.id)))
    "palette" -> Ok(native.palette(parent.ref, palette_entries()))
    "separator" -> Ok(native.tool_separator(parent.ref))
    "status" -> Ok(native.statusbar(shell.frame))
    "notebook" -> Ok(native.notebook(parent.ref, wx_id))
    "page" -> Ok(native.page(parent.ref, wx_id, text))
    "tree" -> Ok(native.tree(parent.ref, wx_id))
    "grid" -> Ok(native.grid(parent.ref, wx_id))
    "editor" -> Ok(native.editor(parent.ref, wx_id))
    "canvas" -> Ok(native.canvas(parent.ref, wx_id))
    "window" | "form" -> Error("nested window is not supported")
    other -> Error("unknown widget kind: " <> other)
  }

  use ref <- result.try(created)
  let design = plan.bool_of(node.props, "design") |> plan.unwrap_or(False)

  case design {
    True -> native.connect_design(ref, kind)
    False -> native.connect(ref, kind)
  }

  // Design-mode containers are otherwise invisible (a plain wxPanel has no
  // chrome), which makes empty panels and groups impossible to find.
  case design {
    True ->
      case kind {
        "panel" | "group" -> native.set_background(ref, 232, 237, 247)
        // Design text is data, not an editor. Read-only fields also stop GTK
        // from eating Ctrl+C/V before the frame accelerators see them.
        "text" | "memo" -> native.set_editable(ref, False)
        _ -> Nil
      }
    False -> Nil
  }

  case kind {
    "menubar" -> native.set_menubar(shell.frame, ref)
    "menu" -> native.append_menu(parent.ref, ref, text)
    _ -> Nil
  }

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
      grow: plan.bool_of(node.props, "grow") |> plan.unwrap_or(False),
    )

  let shell = register(shell, widget)
  let shell = apply_all_props(shell, node.id)
  let shell = case kind {
    "grid" -> {
      configure_grid(ref, node)
      shell
    }
    _ -> shell
  }
  let shell = attach(shell, parent_id, node.id, index)

  let shell = case plan.layout(node), plan.is_container(kind) {
    plan.Column, True -> setup_sizer(shell, node.id, True)
    plan.Row, True -> setup_sizer(shell, node.id, False)
    _, _ -> shell
  }

  use shell <- result.try(mount_children(shell, node.id, node.children))

  case kind {
    "toolbar" -> native.realize_toolbar(ref)
    _ -> Nil
  }

  Ok(#(shell, widget))
}

fn configure_grid(ref: Dynamic, node: Node) -> Nil {
  let show_labels =
    plan.bool_of(node.props, "grid_labels") |> plan.unwrap_or(False)
  let show_lines =
    plan.bool_of(node.props, "grid_lines") |> plan.unwrap_or(False)
  let row_height = plan.int_of(node.props, "row_height") |> plan.unwrap_or(22)
  let label_width =
    plan.int_of(node.props, "label_width") |> plan.unwrap_or(110)
  native.grid_configure(ref, show_labels, show_lines, row_height, label_width)
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
      case is_chrome(child.kind) {
        True -> Nil
        False ->
          case parent.sizer, parent.layout {
            // Free-layout parents position children absolutely, even when a
            // stray sizer object is still attached (the frame root keeps one
            // from `start`): the align pass places these children.
            Some(_), "free" -> native.raise(child.ref)
            Some(sizer), _ ->
              native.insert(
                sizer,
                sizer_index_at(shell, parent, index),
                child.ref,
                parent.border,
                True,
                proportion(child),
              )
            None, _ -> native.raise(child.ref)
          }
      }

      update_widget(shell, parent_id, fn(parent) {
        Widget(..parent, children: insert_at(parent.children, index, child_id))
      })
    }
    _, _ -> shell
  }
}

/// Sizer position for a document child index. Chrome (menus, toolbar, status,
/// pages) never occupies a sizer slot, so count only layout children before
/// `index`; a pure insert in the middle must not be appended.
fn sizer_index_at(shell: Shell, parent: Widget, index: Int) -> Int {
  parent.children
  |> list.take(int.max(0, index))
  |> list.fold(0, fn(count, id) {
    case get_widget(shell, id) {
      Ok(child) ->
        case is_chrome(child.kind) {
          True -> count
          False -> count + 1
        }
      Error(_) -> count
    }
  })
}

fn is_layout_child(shell: Shell, id: String) -> Bool {
  case get_widget(shell, id) {
    Ok(child) -> !is_chrome(child.kind)
    Error(_) -> False
  }
}

fn is_chrome(kind: String) -> Bool {
  case kind {
    "menubar"
    | "menu"
    | "menuitem"
    | "toolbar"
    | "tool"
    | "separator"
    | "status"
    | "page"
    | "palette" -> True
    _ -> False
  }
}

fn proportion(widget: Widget) -> Int {
  case widget.grow {
    True -> 1
    False -> 0
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
    Ok(widget) ->
      case name {
        // Containers can switch layout at runtime (the inspector's
        // none/vertical/horizontal dropdown): rebuild the sizer or detach
        // the children to absolute positioning accordingly.
        "layout" -> apply_layout(shell, widget, id)
        _ -> {
          case name {
            "title" -> {
              let title =
                plan.text_of(widget.props, "title") |> plan.unwrap_or("")
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
            "tooltip" ->
              native.set_tooltip(
                widget.ref,
                plan.text_of(widget.props, "tooltip") |> plan.unwrap_or(""),
              )
            "highlight" ->
              case
                plan.bool_of(widget.props, "highlight") |> plan.unwrap_or(False)
              {
                True -> native.set_background(widget.ref, 199, 220, 250)
                False -> native.set_background(widget.ref, 240, 240, 240)
              }
            "canvas_bg" | "canvas_grid" -> {
              // Keep the widget's own GTK background in the same color (it
              // shows through before the callback paints) ...
              case widget.kind {
                "canvas" ->
                  native.set_background_hex(
                    widget.ref,
                    plan.text_of(widget.props, "canvas_bg")
                      |> plan.unwrap_or(""),
                  )
                _ -> Nil
              }
              // ... and push the new spec through paint_canvas_widget: the
              // repaint itself runs synchronously in the paint callback.
              paint_canvas_widget(shell, widget)
            }
            "x" | "y" | "w" | "h" -> apply_geometry(shell, widget)
            _ -> Nil
          }
          shell
        }
      }
  }
}

fn apply_text(widget: Widget) -> Nil {
  let text = plan.text_of(widget.props, "text") |> plan.unwrap_or("")

  case widget.kind {
    "label" | "button" | "checkbox" | "radio" | "group" | "window" ->
      native.set_label(widget.ref, text)
    "status" -> native.set_status(widget.ref, text)
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

/// Switch a container's layout at runtime. Column/row get a fresh sizer and
/// re-attach the children in order; free detaches them back to absolute
/// positioning and runs the align pass.
fn apply_layout(shell: Shell, widget: Widget, id: String) -> Shell {
  let name = plan.text_of(widget.props, "layout") |> plan.unwrap_or("free")

  case name {
    "column" | "row" -> {
      let sizer = native.box_sizer(name == "column")
      native.set_sizer(widget.ref, sizer)
      widget.children
      |> list.index_map(fn(child_id, index) { #(child_id, index) })
      |> list.each(fn(pair) {
        let #(child_id, index) = pair
        case get_widget(shell, child_id) {
          Ok(child) ->
            case is_chrome(child.kind) {
              True -> Nil
              False -> {
                native.detach(sizer, child.ref)
                native.insert(
                  sizer,
                  index,
                  child.ref,
                  widget.border,
                  True,
                  proportion(child),
                )
              }
            }
          Error(_) -> Nil
        }
      })
      native.layout(widget.ref)
      update_widget(shell, id, fn(w) {
        Widget(..w, sizer: Some(sizer), layout: name)
      })
    }
    _ -> {
      case widget.sizer {
        Some(sizer) ->
          list.each(widget.children, fn(child_id) {
            case get_widget(shell, child_id) {
              Ok(child) -> native.detach(sizer, child.ref)
              Error(_) -> Nil
            }
          })
        None -> Nil
      }

      let shell =
        update_widget(shell, id, fn(w) {
          Widget(..w, sizer: None, layout: "free")
        })
      layout_free_tree(shell, id, None)
      shell
    }
  }
}

pub fn apply(shell: Shell, patches: List(Patch)) -> Result(Shell, String) {
  native.freeze(shell.frame)
  // A reparent moves a node by removing and re-inserting the same id. If the
  // insertion parent comes first in the patch stream, the old widget would be
  // re-registered under that id and the later Remove would destroy the new
  // one. Apply every removal first; ids are unique, so this is safe.
  let removals =
    list.filter(patches, fn(patch) {
      case patch {
        Remove(_) -> True
        _ -> False
      }
    })
  let updates =
    list.filter(patches, fn(patch) {
      case patch {
        Remove(_) -> False
        _ -> True
      }
    })
  let result =
    result.try(list.try_fold(removals, shell, apply_patch), fn(shell) {
      list.try_fold(updates, shell, apply_patch)
    })
  native.thaw(shell.frame)
  native.layout(shell.frame)
  case result {
    Ok(shell) -> {
      relayout_free_children(shell)
      Ok(shell)
    }
    Error(error) -> Error(error)
  }
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
        Ok(#(shell, _widget)) -> Ok(restack(shell, parent_id))
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
            Ok(#(shell, _widget)) -> Ok(restack(shell, parent_id))
            Error(error) -> Error(error)
          }
        }
      }
  }
}

/// Re-raise a free parent's children in document order. `attach` raises the
/// newest child, which is wrong for an insert in the middle of a free layout:
/// hit-testing follows document order, so painting must too.
fn restack(shell: Shell, parent_id: String) -> Shell {
  case get_widget(shell, parent_id) {
    Error(_) -> shell
    Ok(parent) ->
      case parent.sizer {
        Some(_) -> shell
        None -> {
          list.each(parent.children, fn(id) {
            case get_widget(shell, id) {
              Ok(child) ->
                case is_chrome(child.kind) {
                  True -> Nil
                  False -> native.raise(child.ref)
                }
              Error(_) -> Nil
            }
          })
          shell
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
      let layout_ids = list.filter(ids, fn(id) { is_layout_child(shell, id) })

      list.each(layout_ids, fn(id) {
        case get_widget(shell, id) {
          Ok(child) -> native.detach(sizer, child.ref)
          Error(_) -> Nil
        }
      })
      list.index_map(layout_ids, fn(id, index) {
        case get_widget(shell, id) {
          Ok(child) ->
            native.insert(
              sizer,
              index,
              child.ref,
              parent.border,
              True,
              proportion(child),
            )
          Error(_) -> Nil
        }
      })
      Nil
    }
    None ->
      list.each(ids, fn(id) {
        case get_widget(shell, id) {
          Ok(child) ->
            case is_chrome(child.kind) {
              True -> Nil
              False -> native.raise(child.ref)
            }
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
/// The editor's jump list picked an entry: report the chosen "name:line".
/// The adapter decodes the event's text; when it is empty (older wx builds),
/// read the popup selection from the editor itself.
pub fn stc_jump(shell: Shell, wx_id: Int, text: String) -> Incoming {
  case dict.get(shell.by_wx, wx_id) {
    Error(Nil) -> Idle
    Ok(view_id) ->
      case text {
        "" ->
          case get_widget(shell, view_id) {
            Ok(widget) ->
              case native.editor_jumped(widget.ref) {
                Ok(picked) -> Jumped(view_id, picked)
                Error(Nil) -> Idle
              }
            Error(_) -> Idle
          }
        _ -> Jumped(view_id, text)
      }
  }
}

pub fn next(shell: Shell, timeout_ms: Int) -> Incoming {
  case native.next_message(timeout_ms) {
    native.MouseEvent(wx_id, kind, x, y, control)
      if kind == "left_down" || kind == "motion" || kind == "left_up"
    -> design_mouse(shell, wx_id, kind, x, y, control)
    native.MouseEvent(_wx_id, _kind, _x, _y, _control) -> Idle
    native.GridEvent(wx_id, row, col, text) ->
      grid_event(shell, wx_id, row, col, text)
    native.KeyEvent(code, control, shift, alt) ->
      KeyPressed(Key(code: code, control: control, shift: shift, alt: alt))
    native.ShortcutEvent(action) -> Accelerator(action)
    native.WxEvent(wx_id, "close") if wx_id == shell.frame_id -> Closed
    native.WxEvent(wx_id, "close") -> run_closed(shell, wx_id)
    native.WxEvent(wx_id, "paint") -> paint_event(shell, wx_id)
    native.WxEvent(wx_id, "command") -> command_event(shell, wx_id)
    native.WxEvent(_wx_id, "move") -> FrameMoved
    native.WxEvent(_wx_id, "size") -> FrameMoved
    native.WxEvent(_wx_id, _event_type) -> Idle
    native.StcJump(wx_id, text) -> stc_jump(shell, wx_id, text)
    native.Other(message) -> Message(message)
    native.Idle -> Idle
  }
}

fn run_closed(shell: Shell, wx_id: Int) -> Incoming {
  case shell.run {
    Some(run) if wx_id == run.frame_id -> RunClosed
    _ -> Idle
  }
}

/// Find a widget by its wx id in either registry; the flag marks run-window
/// widgets so their events are tagged `RunEvent`.
fn lookup_widget(shell: Shell, wx_id: Int) -> Result(#(Widget, Bool), Nil) {
  case dict.get(shell.by_wx, wx_id) {
    Ok(view_id) ->
      case dict.get(shell.widgets, view_id) {
        Ok(widget) -> Ok(#(widget, False))
        Error(Nil) -> Error(Nil)
      }
    Error(Nil) ->
      case shell.run {
        Some(run) ->
          case dict.get(run.by_wx, wx_id) {
            Ok(view_id) ->
              case dict.get(run.widgets, view_id) {
                Ok(widget) -> Ok(#(widget, True))
                Error(Nil) -> Error(Nil)
              }
            Error(Nil) -> Error(Nil)
          }
        None -> Error(Nil)
      }
  }
}

fn command_event(shell: Shell, wx_id: Int) -> Incoming {
  case native.palette_owner(wx_id) {
    // A palette button press arms the widget kind it depicts.
    Ok(kind) -> Event("palette-" <> kind, "click", VBool(True))
    Error(_) ->
      case lookup_widget(shell, wx_id) {
        Error(Nil) -> Idle
        Ok(#(widget, is_run)) -> {
          case plan.bool_of(widget.props, "design") |> plan.unwrap_or(False) {
            True -> Event(widget.view_id, "select", VText(widget.view_id))
            False -> {
              let key = plan.event_key(widget.kind)
              case list.contains(widget.events, key) {
                False -> Idle
                True ->
                  case is_run {
                    True -> RunEvent(widget.view_id, key, event_value(widget))
                    False -> Event(widget.view_id, key, event_value(widget))
                  }
              }
            }
          }
        }
      }
  }
}

fn grid_event(
  shell: Shell,
  wx_id: Int,
  row: Int,
  col: Int,
  text: String,
) -> Incoming {
  case lookup_widget(shell, wx_id) {
    Error(Nil) -> Idle
    Ok(#(widget, is_run)) ->
      case list.contains(widget.events, "change") {
        False -> Idle
        True ->
          case is_run {
            True ->
              RunEvent(
                widget.view_id,
                "change",
                VMap([
                  #("col", VInt(col)),
                  #("row", VInt(row)),
                  #("text", VText(text)),
                ]),
              )
            False ->
              Event(
                widget.view_id,
                "change",
                VMap([
                  #("col", VInt(col)),
                  #("row", VInt(row)),
                  #("text", VText(text)),
                ]),
              )
          }
      }
  }
}

/// The view event a widget reports for its connected wx event.
fn event_value(widget: Widget) -> Value {
  case widget.kind {
    "text" | "memo" -> VText(native.get_text(widget.ref))
    "checkbox" | "radio" -> VBool(native.get_bool(widget.ref, widget.kind))
    "choice" | "list" -> VInt(native.get_selection(widget.ref, widget.kind))
    "slider" -> VInt(native.get_int(widget.ref, widget.kind))
    "progress" -> VInt(native.get_int(widget.ref, widget.kind))
    "notebook" -> VInt(native.notebook_selection(widget.ref))
    "tree" -> VText(native.tree_selected_key(widget.ref))
    "grid" ->
      case native.grid_cell(widget.ref) {
        native.GridCell(row, col, text) ->
          VMap([
            #("col", VInt(col)),
            #("row", VInt(row)),
            #("text", VText(text)),
          ])
      }
    _ -> VBool(True)
  }
}

/// Paint a canvas: background, grid, chrome, and border, in form coordinates.
/// Canvases in either window resolve here; the paint extent is the widget's
/// actual client size, so a maximized window fills with grid.
pub fn paint(shell: Shell, id: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> paint_canvas_widget(shell, widget)
    Error(_) ->
      case run_widget(shell, id) {
        Ok(widget) -> paint_canvas_widget(shell, widget)
        Error(_) -> Nil
      }
  }
}

fn run_widget(shell: Shell, id: String) -> Result(Widget, Nil) {
  case shell.run {
    Some(run) -> dict.get(run.widgets, id)
    None -> Error(Nil)
  }
}

fn paint_canvas_widget(shell: Shell, widget: Widget) -> Nil {
  case widget.kind {
    "canvas" -> {
      let #(actual_w, actual_h) = native.client_size(widget.ref)
      let width = case actual_w > 0 {
        True -> actual_w
        False -> plan.int_of(widget.props, "w") |> plan.unwrap_or(400)
      }
      let height = case actual_h > 0 {
        True -> actual_h
        False -> plan.int_of(widget.props, "h") |> plan.unwrap_or(300)
      }
      let grid = plan.int_of(widget.props, "grid") |> plan.unwrap_or(24)
      let bg =
        plan.text_of(widget.props, "canvas_bg") |> plan.unwrap_or("#f5f6f8")
      let grid_color =
        plan.text_of(widget.props, "canvas_grid")
        |> plan.unwrap_or("#e2e4e8")
      let chrome = case widget.view_id == "canvas" {
        True -> shell.chrome
        False -> empty_chrome()
      }
      native.paint_canvas(
        widget.ref,
        width,
        height,
        grid,
        chrome.marquee,
        bg,
        grid_color,
      )
    }
    _ -> Nil
  }
}

fn design_mouse(
  shell: Shell,
  wx_id: Int,
  kind: String,
  x: Int,
  y: Int,
  control: Bool,
) -> Incoming {
  case native.grab_owner(wx_id) {
    // A press/motion/release on a grab strip reports in the decorated
    // widget's space: strip-relative coordinates plus the strip's offset.
    Ok(#(widget_id, dx, dy)) -> Mouse(widget_id, kind, x + dx, y + dy, control)
    Error(_) ->
      case native.plate_owner(wx_id) {
        // A press on the form plate reports in the form's space (the plate
        // origin is the form's editor position).
        Ok(form_id) -> Mouse(form_id, kind, x, y, control)
        Error(_) ->
          case dict.get(shell.by_wx, wx_id) {
            Error(Nil) -> Idle
            Ok(view_id) ->
              case dict.get(shell.widgets, view_id) {
                Error(Nil) -> Idle
                Ok(widget) ->
                  case
                    plan.bool_of(widget.props, "design")
                    |> plan.unwrap_or(False)
                  {
                    True -> Mouse(widget.view_id, kind, x, y, control)
                    False -> Idle
                  }
              }
          }
      }
  }
}

fn paint_event(shell: Shell, wx_id: Int) -> Incoming {
  case lookup_widget(shell, wx_id) {
    Ok(#(widget, _)) -> Paint(widget.view_id)
    Error(Nil) -> Idle
  }
}

/// Selection chrome: four yellow grab strips around each selected widget,
/// protruding 3px on every side. The strips never overlap the widget, so
/// windowless widgets (labels) stay visible; with a single selection the
/// strips start resizes and the control body starts a move. The strips are
/// raised above the siblings; the widget itself keeps its own depth, so
/// deselect has nothing to restore. The form root is selectable too: its
/// plate (form_plate_show) acts as the widget.
pub fn show_selection(shell: Shell, ids: List(String)) -> Nil {
  list.each(native.grab_list(), fn(view_id) {
    case list.contains(ids, view_id) {
      True -> Nil
      False -> native.grab_hide(view_id)
    }
  })

  list.each(ids, fn(id) {
    case grab_target(shell, id) {
      Ok(#(parent_ref, rect)) -> {
        let #(x, y, w, h) = rect
        case list.contains(native.grab_list(), id) {
          True -> native.grab_move(id, x, y, w, h)
          False -> native.grab_show(id, parent_ref, x, y, w, h)
        }
      }
      Error(_) -> native.grab_hide(id)
    }
  })
}

/// A selection target: the parent to draw chrome in, and the widget's
/// rectangle in that parent's coordinates. View widgets resolve through the
/// registry; the form root resolves through its plate.
fn grab_target(
  shell: Shell,
  id: String,
) -> Result(#(Dynamic, #(Int, Int, Int, Int)), Nil) {
  case get_widget(shell, id) {
    Ok(widget) ->
      case widget.parent {
        Some(parent_id) ->
          case get_widget(shell, parent_id) {
            Ok(parent) ->
              case native.widget_rect(widget.ref) {
                Ok(rect) -> Ok(#(parent.ref, rect))
                Error(_) -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        None ->
          case native.widget_rect(widget.ref) {
            Ok(rect) -> Ok(#(shell.frame, rect))
            Error(_) -> Error(Nil)
          }
      }
    Error(_) ->
      // The form root's plate is its widget; the strips draw in the canvas
      // (the plate's parent), since child windows clip to their parent.
      case native.form_plate_rect(id) {
        Ok(rect) -> {
          let #(canvas, _, _) = canvas_widget(shell)
          Ok(#(canvas, rect))
        }
        Error(_) -> Error(Nil)
      }
  }
}

/// Marquee outline while a placement/selection drag is active. The rect is
/// recorded in the canvas paint spec (read synchronously by the paint
/// callback) and the canvas is queued for repaint.
pub fn show_marquee(shell: Shell, rect: Option(#(Int, Int, Int, Int))) -> Nil {
  let shell = Shell(..shell, chrome: Chrome(marquee: rect))
  case get_widget(shell, "canvas") {
    Ok(widget) -> paint_canvas_widget(shell, widget)
    Error(_) -> Nil
  }
  invalidate_canvas(shell)
}

/// Repaint the whole frame: refresh queues an expose and update flushes the
/// pending paint immediately. Text set outside a wx event (draining app
/// replies) leaves editor pixels stale otherwise.
pub fn repaint(shell: Shell) -> Nil {
  native.refresh(shell.frame)
  native.update(shell.frame)
}

/// Lay out the sizers of widgets whose parent positions children freely, and
/// re-resolve every free-layout container's children from their align props
/// against the container's actual client size. Free-layout parents are not
/// managed by any sizer, so the frame-level layout pass never recalculates
/// their children; the align pass runs after patches and on every frame
/// resize, so panes follow maximize/restore.
pub fn relayout_free_children(shell: Shell) -> Nil {
  dict.values(shell.widgets)
  |> list.each(fn(widget) {
    case widget.sizer, widget.parent {
      Some(sizer), Some(parent_id) ->
        case get_widget(shell, parent_id) {
          Ok(parent) ->
            case parent.sizer {
              None -> native.layout_sizer(widget.ref, sizer)
              Some(_) -> Nil
            }
          Error(_) -> Nil
        }
      _, _ -> Nil
    }
  })

  // Align pass: walk every root window's free-layout tree, docking children
  // from their align props and handing each nested container its freshly
  // resolved rectangle, so nothing re-reads a stale wx size mid-pass.
  dict.values(shell.widgets)
  |> list.filter(fn(widget) { widget.parent == None })
  |> list.each(fn(root) { layout_free_tree(shell, root.view_id, None) })

  // Notebook pages are layout roots of their own: the notebook sizes the
  // page, and the page docks its children (the design canvas fills its
  // page this way). is_container does not count "notebook", so the walk
  // above stops at the tabs — give each page its own pass.
  dict.values(shell.widgets)
  |> list.filter(fn(widget) { widget.kind == "page" })
  |> list.each(fn(page) { layout_free_tree(shell, page.view_id, None) })

  case shell.run {
    Some(run) ->
      dict.values(run.widgets)
      |> list.filter(fn(widget) { widget.parent == None })
      |> list.each(fn(root) {
        layout_free_tree(run_as_shell(run), root.view_id, None)
      })
    None -> Nil
  }
}

/// Dock a free-layout container's children, then recurse into child
/// containers. `override` carries the container's freshly resolved size for
/// nested passes; None reads the widget's actual wx client size (roots, and
/// sizer-managed containers whose sizer was just laid out).
fn layout_free_tree(
  shell: Shell,
  parent_id: String,
  override: Option(#(Int, Int)),
) -> Nil {
  case get_widget(shell, parent_id) {
    Error(_) -> Nil
    Ok(parent) -> {
      let #(client_w, client_h) = case override {
        Some(#(w, h)) -> #(w, h)
        None -> native.client_size(parent.ref)
      }

      case parent.layout {
        "free" -> {
          let children =
            parent.children
            |> list.filter_map(fn(child_id) {
              case get_widget(shell, child_id) {
                Ok(child) ->
                  Ok(
                    campy_view.node(child.kind, child.view_id)
                    |> campy_view.with_props(child.props),
                  )
                Error(_) -> Error(Nil)
              }
            })
          let frame =
            campy_view.node(parent.kind, parent.view_id)
            |> campy_view.with_props(
              list.append(parent.props, [
                // Runtime geometry: only the size applies (the form's
                // recorded position is editor-only chrome).
                #("x", VInt(0)),
                #("y", VInt(0)),
                #("w", VInt(int.max(client_w, 1))),
                #("h", VInt(int.max(client_h, 1))),
                #("layout", VText("free")),
                #("border", VInt(parent.border)),
              ]),
            )
            |> campy_view.with_children(children)
          let resolved = campy_design.resolve(frame)

          list.each(parent.children, fn(child_id) {
            case get_widget(shell, child_id) {
              Ok(child) ->
                case is_chrome(child.kind) {
                  True -> Nil
                  False ->
                    case
                      list.find(resolved.places, fn(place) {
                        place.id == child_id && place.parent == Some(parent_id)
                      })
                    {
                      Ok(place) -> {
                        native.move(child.ref, place.rect.x, place.rect.y)
                        native.resize(
                          child.ref,
                          int.max(place.rect.w, 1),
                          int.max(place.rect.h, 1),
                        )
                        // Nested containers continue with their fresh rect.
                        case campy_design.is_container(child.kind) {
                          True ->
                            layout_free_tree(
                              shell,
                              child_id,
                              Some(#(place.rect.w, place.rect.h)),
                            )
                          False -> Nil
                        }
                      }
                      Error(_) -> Nil
                    }
                }
              Error(_) -> Nil
            }
          })
        }
        _ ->
          // Sizer-managed container: re-layout its sizer at the current
          // size, then descend. Its children's wx sizes are fresh after
          // wxSizer:layout, so nested passes read the widget again.
          case parent.sizer {
            Some(sizer) -> native.layout_sizer(parent.ref, sizer)
            None -> Nil
          }
      }

      // Sizer-managed containers still descend (their subtree may hold free
      // containers); their children's rects come from wx, now fresh.
      case parent.layout {
        "free" -> Nil
        _ ->
          list.each(parent.children, fn(child_id) {
            case get_widget(shell, child_id) {
              Ok(child) ->
                case campy_design.is_container(child.kind) {
                  True -> layout_free_tree(shell, child_id, None)
                  False -> Nil
                }
              Error(_) -> Nil
            }
          })
      }
    }
  }
}

/// A canvas repaint draws background, grid, and the current chrome.
pub fn invalidate_canvas(shell: Shell) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.refresh(canvas)
}

/// Cursor feedback for hit-tested handles: pass the role under the pointer,
/// or anything outside 0..8 to restore the arrow.
fn canvas_widget(shell: Shell) -> #(Dynamic, Int, Int) {
  case
    list.find(dict.values(shell.widgets), fn(widget) { widget.kind == "canvas" })
  {
    Ok(widget) -> #(
      widget.ref,
      plan.int_of(widget.props, "w") |> plan.unwrap_or(600),
      plan.int_of(widget.props, "h") |> plan.unwrap_or(400),
    )
    Error(Nil) -> #(shell.frame, 600, 400)
  }
}

pub fn set_canvas_cursor(shell: Shell, role: Int) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.set_cursor(canvas, role)
}

pub fn capture_canvas(shell: Shell) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.capture(canvas)
}

pub fn release_canvas(shell: Shell) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.release(canvas)
  native.release_capture()
}

pub fn set_tree(shell: Shell, id: String, items: List(plan.TreeItem)) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.tree_set(widget.ref, items)
    Error(_) -> Nil
  }
}

pub fn set_selection(shell: Shell, id: String, index: Int) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.set_selection(widget.ref, widget.kind, index)
    Error(_) -> Nil
  }
}

pub fn set_grid(shell: Shell, id: String, rows: List(List(String))) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.grid_set(widget.ref, rows)
    Error(_) -> Nil
  }
}

/// Give a grid cell the integer editor. Cells outside the number rows keep the
/// default text editor, so labels and text values remain editable as text.
pub fn set_grid_number_cell(
  shell: Shell,
  id: String,
  row: Int,
  col: Int,
  min: Int,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.grid_number_cell(widget.ref, row, col, min)
    Error(_) -> Nil
  }
}

pub fn set_grid_text_cell(shell: Shell, id: String, row: Int, col: Int) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.grid_text_cell(widget.ref, row, col)
    Error(_) -> Nil
  }
}

/// Give an inspector cell a dropdown editor (enum properties).
pub fn set_grid_choice_cell(
  shell: Shell,
  id: String,
  row: Int,
  col: Int,
  options: List(String),
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.grid_choice_cell(widget.ref, row, col, options)
    Error(_) -> Nil
  }
}

pub fn set_grid_read_only(
  shell: Shell,
  id: String,
  row: Int,
  col: Int,
  read_only: Bool,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.grid_read_only(widget.ref, row, col, read_only)
    Error(_) -> Nil
  }
}

/// Fill a list/choice in place. Unlike `set_grid`, the widget owns no view
/// state beyond its items, so list boxes can be refreshed freely.
pub fn set_items(shell: Shell, id: String, items: List(String)) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.set_items(widget.ref, widget.kind, items)
    Error(_) -> Nil
  }
}

pub fn set_editor(
  shell: Shell,
  id: String,
  text: String,
  read_only: Bool,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> {
      native.editor_set(widget.ref, text, read_only)
      native.refresh(widget.ref)
    }
    Error(_) -> Nil
  }
}

/// Scroll an editor to its end. Used when a handler stub is appended so the
/// new source is visible instead of leaving the view at the top of the file.
pub fn scroll_editor_to_end(shell: Shell, id: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_show_end(widget.ref)
    Error(_) -> Nil
  }
}

/// Turn on Gleam syntax highlighting for a text editor. Idempotent: safe to
/// call again after the widget is recreated by a view patch.
pub fn highlight_gleam(shell: Shell, id: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_gleam(widget.ref)
    Error(_) -> Nil
  }
}

/// Token-color a highlighted editor's buffer with the given text (the text
/// the caller just put in the editor — reading it back through wx in the same
/// command batch can return stale content). Call after every `set_editor`.
pub fn style_gleam(shell: Shell, id: String, text: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_style_gleam(widget.ref, text)
    Error(_) -> Nil
  }
}

/// The full text currently in a text editor (Scintilla keeps its own buffer,
/// which differs from the last `set_editor` call once the user has typed).
pub fn editor_text(shell: Shell, id: String) -> String {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_get_text(widget.ref)
    Error(_) -> ""
  }
}

/// The caret of a text editor as a 0-based #(Line, Column) pair.
pub fn editor_caret(shell: Shell, id: String) -> #(Int, Int) {
  case get_widget(shell, id) {
    Ok(widget) -> {
      let native.Caret(line, column) = native.editor_caret(widget.ref)
      #(line, column)
    }
    Error(_) -> #(0, 0)
  }
}

/// Move a text editor's caret to a 0-based line/column and make it visible.
/// Used for jump-to-declaration.
pub fn goto_editor_position(
  shell: Shell,
  id: String,
  line: Int,
  column: Int,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_goto(widget.ref, line, column)
    Error(_) -> Nil
  }
}

/// Show a jump-to-symbol list in a text editor's completion popup; entries
/// are "name:line". The picked entry arrives as `Jumped` on the shell.
pub fn editor_jump_list(
  shell: Shell,
  id: String,
  entries: List(String),
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_jump_list(widget.ref, entries)
    Error(_) -> Nil
  }
}

/// Paint language-server diagnostics on a text editor: squiggle underlines
/// under the offending lines plus a margin marker per finding. Rows are
/// #(StartLine, EndLine, Message, Severity), 0-based lines, LSP severities.
pub fn editor_diagnostics(
  shell: Shell,
  id: String,
  rows: List(#(Int, Int, String, Int)),
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_diagnostics(widget.ref, rows)
    Error(_) -> Nil
  }
}

/// Show a completion popup at a text editor's caret with the given labels.
pub fn editor_completions(
  shell: Shell,
  id: String,
  labels: List(String),
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_autocomplete(widget.ref, labels)
    Error(_) -> Nil
  }
}

pub fn set_status(shell: Shell, text: String) -> Nil {
  case
    list.find(dict.values(shell.widgets), fn(widget) { widget.kind == "status" })
  {
    Ok(widget) -> native.set_status(widget.ref, text)
    Error(Nil) -> Nil
  }
}

/// A native message dialog, used by Help > Keyboard shortcuts.
pub fn show_message(shell: Shell, title: String, message: String) -> Nil {
  native.show_message(shell.frame, title, message)
}

/// Apply the scheme palette to a text editor's Scintilla styles.
pub fn apply_scheme(
  shell: Shell,
  id: String,
  palette: List(#(String, String)),
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_scheme(widget.ref, palette)
    Error(_) -> Nil
  }
}

/// Apply the settings font family and size to a text editor.
pub fn apply_editor_font(
  shell: Shell,
  id: String,
  face: String,
  size: Int,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_font(widget.ref, face, size)
    Error(_) -> Nil
  }
}

/// The modal Settings → Editor… dialog; indexes address the caller's lists.
pub fn show_settings_dialog(
  shell: Shell,
  fonts: List(String),
  sizes: List(String),
  schemes: List(String),
  font_index: Int,
  size_index: Int,
  scheme_index: Int,
) -> Result(#(Int, Int, Int), Nil) {
  native.settings_dialog(
    shell.frame,
    fonts,
    sizes,
    schemes,
    font_index,
    size_index,
    scheme_index,
  )
}

/// The modal Settings → Agent… dialog: MCP enable checkbox and port text.
pub fn show_agent_dialog(
  shell: Shell,
  enabled: Bool,
  port: String,
  status: String,
  endpoint: String,
) -> Result(#(Bool, String), Nil) {
  native.agent_dialog(shell.frame, enabled, port, status, endpoint)
}

/// Rebuild the frame accelerator table for the active page. Text shortcuts
/// are omitted while Code/Source is visible so the editor keeps them.
pub fn set_shortcuts(shell: Shell, editing: Bool) -> Nil {
  native.set_shortcuts(shell.frame, editing)
  // wx consults the focused window's accelerator table, not only the frame's.
  // Apply it to every widget so a focused notebook tab (the Form page's usual
  // focus) cannot swallow Ctrl+C/V/Z. On Code/Source the table omits the text
  // shortcuts, so Scintilla still owns them.
  list.each(dict.values(shell.widgets), fn(widget) {
    native.apply_shortcuts(widget.ref)
  })
}

pub fn set_tooltip(shell: Shell, id: String, text: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.set_tooltip(widget.ref, text)
    Error(_) -> Nil
  }
}

/// Apply a clipboard/undo command to a text editor by view id.
pub fn editor_clipboard(shell: Shell, id: String, action: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.editor_clipboard(widget.ref, action)
    Error(_) -> Nil
  }
}

/// Create or reposition the form plate: the form as a selectable white panel
/// on the canvas at the form's editor position, kept below the controls.
pub fn form_plate_show(
  shell: Shell,
  id: String,
  parent_id: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> Nil {
  case get_widget(shell, parent_id) {
    Ok(parent) -> native.form_plate_set(id, parent.ref, x, y, w, h)
    Error(_) -> Nil
  }
}

/// Destroy every form plate except the one for this form view id: switching
/// modules must not stack plates on the canvas.
pub fn form_plate_retain(view_id: String) -> Nil {
  native.form_plate_retain(view_id)
}

/// The pointer position in the design canvas' coordinates: drags read the
/// true pointer so a moving widget cannot shift the coordinate base.
pub fn canvas_pointer(shell: Shell) -> #(Int, Int) {
  let #(canvas, _, _) = canvas_widget(shell)
  native.pointer_in(canvas)
}

// ---------------------------------------------------------------------------
// Probe support: synthetic event injection through the real message pump, so
// scripted tests drive the real IDE loop end to end.
// ---------------------------------------------------------------------------

/// A view widget's wx id (event attribution for synthetic events).
pub fn probe_wx_id(shell: Shell, view_id: String) -> Result(Int, Nil) {
  native.view_wx_id(shell, view_id)
}

/// A view widget's native ref (for pointer warps and event payloads).
pub fn probe_ref(shell: Shell, view_id: String) -> Result(Dynamic, Nil) {
  native.view_ref(shell, view_id)
}

/// Override the pointer position drags read (deterministic scripted
/// gestures; production keeps the real pointer).
pub fn probe_pointer(x: Int, y: Int) -> Nil {
  native.pointer_override(x, y)
}

pub fn probe_pointer_clear() -> Nil {
  native.pointer_clear()
}

/// The top grab strip's wx id for a selection (strip presses start resizes).
pub fn probe_grab_strip(view_id: String) -> Result(Int, Nil) {
  native.grab_strip_wx_id(view_id)
}

/// A grab strip's wx id and offset by index (0=top, 1=bottom, 2=left,
/// 3=right), for scripted strip presses.
pub fn probe_strip(
  view_id: String,
  index: Int,
) -> Result(#(Int, Int, Int), Nil) {
  native.grab_strip_info(view_id, index)
}

/// A palette tool's wx id by widget kind.
pub fn probe_palette_tool(kind: String) -> Result(Int, Nil) {
  native.palette_tool(kind)
}

/// The form plate's wx id (presses select and drag the form).
pub fn probe_plate(view_id: String) -> Result(Int, Nil) {
  native.plate_wx_id(view_id)
}

/// The open enum dropdown's list ref, for scripted picks.
pub fn probe_enum_list() -> Result(Dynamic, Nil) {
  native.enum_popup_list()
}

/// Preselect an option in the open enum dropdown (as a user click would).
pub fn probe_enum_select(index: Int) -> Nil {
  native.enum_popup_select(index)
}

/// Dev instrumentation (CAMPY_DUMP=1): one line per registered widget,
/// printed to the IDE's stdout for live geometry debugging.
pub fn dump_widgets(shell: Shell) -> Nil {
  native.widget_report(shell)
}

/// Is the open dropdown anchored at its cell? (probe assertion)
pub fn probe_enum_anchored() -> Bool {
  case native.enum_popup_anchored() {
    Ok(True) -> True
    _ -> False
  }
}

/// Read an inspector grid cell (probe assertions).
pub fn probe_inspector_cell(shell: Shell, row: Int, col: Int) -> String {
  native.inspector_cell(shell, row, col)
}

/// Inject a synthetic mouse event into the pump.
pub fn probe_mouse(
  shell: Shell,
  view_id: String,
  kind: String,
  x: Int,
  y: Int,
  control: Bool,
) -> Nil {
  // The form root is not a view widget: its presses ride the plate's id.
  let wx_id = case probe_wx_id(shell, view_id) {
    Ok(id) -> Ok(id)
    Error(_) -> probe_plate(view_id)
  }
  let payload = case probe_ref(shell, view_id) {
    Ok(ref) -> ref
    Error(_) -> native.null_ref()
  }
  case wx_id {
    Ok(id) -> native.inject_mouse(id, payload, kind, x, y, control)
    Error(_) -> Nil
  }
}

/// Inject a synthetic command event (menu items, palette tools).
pub fn probe_command(shell: Shell, view_id: String, kind: String) -> Nil {
  case probe_wx_id(shell, view_id) {
    Ok(wx_id) -> native.inject_command(wx_id, kind, wx_id)
    Error(_) -> Nil
  }
}

/// Inject a synthetic grid cell selection (enum dropdowns open on select).
pub fn probe_grid_select(
  shell: Shell,
  view_id: String,
  row: Int,
  col: Int,
) -> Nil {
  case probe_ref(shell, view_id) {
    Ok(ref) -> native.inject_grid_select(ref, row, col)
    Error(_) -> Nil
  }
}

/// Inject a grab-strip press (starts a resize in the real loop).
pub fn probe_strip_press(wx_id: Int, x: Int, y: Int) -> Nil {
  native.inject_strip_press(wx_id, x, y)
}

/// Inject a form-plate press (selects/moves the form in the real loop).
pub fn probe_plate_press(wx_id: Int, x: Int, y: Int) -> Nil {
  native.inject_plate_press(wx_id, x, y)
}

/// Inject a palette tool press (arms the widget kind).
pub fn probe_tool_press(wx_id: Int) -> Nil {
  native.inject_tool_press(wx_id)
}

/// The form plate's current rectangle (probe assertions).
pub fn probe_plate_rect(view_id: String) -> Result(#(Int, Int, Int, Int), Nil) {
  native.form_plate_rect(view_id)
}

/// Toolbar diagnostics (probe assertions): tool size, bitmap size, and the
/// toolbar's client/frame size.
pub fn probe_toolbar_stats(
  shell: Shell,
) -> Result(#(#(Int, Int), #(Int, Int), #(Int, Int), #(Int, Int)), Nil) {
  case probe_ref(shell, "toolbar") {
    Ok(bar) -> Ok(native.toolbar_stats(bar))
    Error(_) -> Error(Nil)
  }
}

/// Capture a window's content to a PNG (probe diagnostics).
pub fn probe_snapshot(shell: Shell, view_id: String, path: String) -> Nil {
  case probe_ref(shell, view_id) {
    Ok(ref) -> native.snapshot(ref, path)
    Error(_) -> Nil
  }
}

/// Inject a synthetic enum dropdown pick (as a user click would commit).
pub fn probe_list_pick(text: String, index: Int) -> Nil {
  case native.enum_popup_list() {
    Ok(list) -> {
      let list_id = case native.enum_popup_wx_id() {
        Ok(id) -> id
        Error(_) -> 0
      }
      native.inject_list_pick(list_id, list, text, index)
    }
    Error(_) -> Nil
  }
}

/// Run/Stop tools get pictograms; the rest keep their text labels.
fn tool_icon_kind(id: String) -> String {
  case id {
    "tool-run" -> "run"
    "tool-stop" -> "stop"
    _ -> "none"
  }
}

/// The palette entries: one pictogram button per catalog widget, with the
/// widget name plus the placement hint as its tooltip.
fn palette_entries() -> List(#(String, String)) {
  campy_catalog.all()
  |> list.map(fn(widget) {
    #(widget.kind, widget.label <> " — click, then drag on the form")
  })
}

/// Move/resize a control's live widget without touching the document. Used for
/// drag previews; the commit goes through `campy_design.set_rect` and the model.
/// The widget's grab panel (if selected) follows.
pub fn preview_rect(
  shell: Shell,
  id: String,
  x: Int,
  y: Int,
  width: Int,
  height: Int,
) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> {
      native.move(widget.ref, x, y)
      native.resize(widget.ref, width, height)
      native.grab_move(id, x, y, width, height)
    }
    Error(_) ->
      // The form root previews through its plate.
      case native.form_plate_get(id) {
        Ok(plate) -> {
          native.move(plate, x, y)
          native.resize(plate, width, height)
          native.grab_move(id, x, y, width, height)
        }
        Error(_) -> Nil
      }
  }
}

pub fn freeze_canvas(shell: Shell) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.freeze(canvas)
}

pub fn thaw_canvas(shell: Shell) -> Nil {
  let #(canvas, _, _) = canvas_widget(shell)
  native.thaw(canvas)
}

pub fn select_page(shell: Shell, id: String, index: Int) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) -> native.select_page(widget.ref, index)
    Error(_) -> Nil
  }
}

pub fn focus(shell: Shell, id: String) -> Nil {
  case get_widget(shell, id) {
    Ok(widget) ->
      case widget.kind {
        "canvas" -> native.focus_ignoring_children(widget.ref)
        _ -> native.focus(widget.ref)
      }
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
