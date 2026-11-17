//// Display-free IDE state.
////
//// The wx shell (`campy_ide_wx`, T1.4) owns no document logic: it renders this
//// state and sends commands here. Everything in this module is pure, so the
//// IDE's behaviour is testable without a display.
////
//// M2 adds designer edits: placement from the palette, reparenting, z-order,
//// clipboard, duplication, deletion, and geometry commits. Every edit ends in
//// `commit`, so the shell only has to re-render the result and undo works for
//// each user gesture.

import campy_catalog
import campy_design
import campy_project.{type Module, type Project}
import campy_view.{type Node, VInt}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const console_limit = 500

pub const undo_limit = 100

pub type State {
  State(
    project: Project,
    open_tabs: List(String),
    active: Option(String),
    selection: List(String),
    console: List(String),
    undo: List(Project),
    redo: List(Project),
    status: String,
    code_view: Bool,
    /// Copied subtrees, in selection order. Copies are cloned again on paste so
    /// pasting twice does not create duplicate ids.
    clipboard: List(Node),
    /// Palette kind armed for placement, if any. UI intent, not a document
    /// field; placing a control disarms it.
    armed: Option(String),
  )
}

pub type Command {
  OpenModule(String)
  CloseModule(String)
  SelectControls(List(String))
  Commit(Project)
  Undo
  Redo
  Log(String)
  SetStatus(String)
  ToggleCodeView
  Arm(String)
  Disarm
  PlaceWidget(kind: String, x: Int, y: Int, w: Int, h: Int)
  CopySelection
  CutSelection
  Paste
  DuplicateSelection
  DeleteSelection
  BringToFront
  SendToBack
  CommitGeometry(
    items: List(#(String, campy_design.Rect)),
    reparent: Option(#(String, String)),
  )
}

pub fn new(project: Project) -> State {
  let state =
    State(
      project: project,
      open_tabs: [],
      active: None,
      selection: [],
      console: [],
      undo: [],
      redo: [],
      status: "",
      code_view: False,
      clipboard: [],
      armed: None,
    )

  case project.modules {
    [] -> state
    [first, ..] ->
      case open_module(state, first.slug) {
        Ok(state) -> state
        Error(_) -> state
      }
  }
}

pub fn open_module(state: State, slug: String) -> Result(State, String) {
  use _module <- result.try(campy_project.module(state.project, slug))

  let open_tabs = case list.contains(state.open_tabs, slug) {
    True -> state.open_tabs
    False -> list.append(state.open_tabs, [slug])
  }

  Ok(State(..state, open_tabs: open_tabs, active: Some(slug), selection: []))
}

pub fn close_module(state: State, slug: String) -> State {
  let open_tabs = list.filter(state.open_tabs, fn(tab) { tab != slug })

  let active = case state.active {
    Some(current) if current == slug ->
      case open_tabs {
        [next, ..] -> Some(next)
        [] -> None
      }
    _ -> state.active
  }

  State(..state, open_tabs: open_tabs, active: active, selection: [])
}

pub fn select_controls(state: State, ids: List(String)) -> State {
  State(..state, selection: ids)
}

/// Replace the project with a new snapshot, recording undo. An unchanged
/// project is not recorded, so repeated no-op edits do not fill the history.
pub fn commit(state: State, project: Project) -> State {
  case project == state.project {
    True -> state
    False ->
      State(
        ..state,
        project: project,
        undo: list.take([state.project, ..state.undo], undo_limit),
        redo: [],
      )
  }
}

pub fn undo(state: State) -> State {
  case state.undo {
    [] -> state
    [previous, ..rest] ->
      State(
        ..state,
        project: previous,
        undo: rest,
        redo: list.take([state.project, ..state.redo], undo_limit),
      )
  }
}

pub fn redo(state: State) -> State {
  case state.redo {
    [] -> state
    [next, ..rest] ->
      State(
        ..state,
        project: next,
        redo: rest,
        undo: list.take([state.project, ..state.undo], undo_limit),
      )
  }
}

pub fn log(state: State, line: String) -> State {
  State(..state, console: list.take([line, ..state.console], console_limit))
}

pub fn set_status(state: State, text: String) -> State {
  State(..state, status: text)
}

pub fn toggle_code_view(state: State) -> State {
  State(..state, code_view: !state.code_view)
}

pub fn arm(state: State, kind: String) -> State {
  case campy_catalog.find(kind) {
    Ok(widget) ->
      State(..state, armed: Some(kind))
      |> set_status("Place " <> widget.label <> ": click or drag on the canvas")
    Error(error) -> set_status(state, error)
  }
}

pub fn disarm(state: State) -> State {
  State(..state, armed: None)
}

pub fn active_module(state: State) -> Result(Module, String) {
  case state.active {
    None -> Error("no active module")
    Some(slug) -> campy_project.module(state.project, slug)
  }
}

/// Replace the active module's form with `view`, recording one undo entry.
pub fn commit_view(state: State, module: Module, view: Node) -> State {
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

  commit(
    state,
    campy_project.Project(
      title: state.project.title,
      modules: modules,
      extra: state.project.extra,
    ),
  )
}

/// Place a catalog widget with its top-left at canvas coordinates `x, y`.
/// The drop adopts the deepest container under the point; the document is
/// frozen first so an existing column/row layout cannot drag the control back
/// into a stack.
pub fn place_widget(
  state: State,
  kind: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let root = campy_design.freeze(module.form.view)
      let layout = campy_design.resolve(root)
      let #(parent_id, origin_x, origin_y) = drop_target(root, layout, x, y)
      let id = fresh_id(campy_view.ids(root), kind)
      let width = case w > 0 {
        True -> w
        False -> campy_catalog.default_w(kind)
      }
      let height = case h > 0 {
        True -> h
        False -> campy_catalog.default_h(kind)
      }

      let made =
        campy_catalog.make_at(
          kind,
          id,
          int.max(0, x - origin_x),
          int.max(0, y - origin_y),
          width,
          height,
        )

      case made {
        Error(error) -> set_status(state, error)
        Ok(node) ->
          case
            campy_design.insert_child(
              root,
              parent_id,
              campy_design.child_count(root, parent_id),
              node,
            )
          {
            Error(error) -> set_status(state, error)
            Ok(view) ->
              state
              |> commit_view(module, view)
              |> select_controls([id])
              |> disarm()
              |> set_status("Added " <> campy_catalog.label_of(kind))
          }
      }
    }
  }
}

fn drop_target(
  root: Node,
  layout: campy_design.Layout,
  x: Int,
  y: Int,
) -> #(String, Int, Int) {
  case campy_design.container_for_drop(root, layout, x, y, None) {
    Some(placed) -> #(placed.id, placed.rect.x, placed.rect.y)
    None ->
      case campy_design.placed(layout, layout.root) {
        Some(placed) -> #(placed.id, placed.rect.x, placed.rect.y)
        None -> #(layout.root, 0, 0)
      }
  }
}

/// Copy the selected top-level subtrees into the clipboard.
pub fn copy_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)
      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ ->
          State(..state, clipboard: nodes)
          |> set_status("Copied " <> int.to_string(list.length(nodes)))
      }
    }
  }
}

/// Copy the selection, then delete it. The clipboard survives the deletion, so
/// Cut followed by Paste works like a move.
pub fn cut_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)
      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let count = int.to_string(list.length(nodes))
          State(..state, clipboard: nodes)
          |> delete_selection()
          |> set_status("Cut " <> count)
        }
      }
    }
  }
}

/// Remove the selected top-level subtrees. One undo entry covers the gesture.
pub fn delete_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)
      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let view =
            list.fold(nodes, module.form.view, fn(view, node) {
              case campy_design.remove_node(view, node.id) {
                Ok(#(updated, _removed)) -> updated
                Error(_) -> view
              }
            })

          state
          |> commit_view(module, view)
          |> select_controls([])
          |> set_status("Deleted " <> int.to_string(list.length(nodes)))
        }
      }
    }
  }
}

/// Paste clipboard subtrees with fresh ids. A selected container receives the
/// children; otherwise they become siblings after the selection, or top-level
/// children when nothing is selected.
pub fn paste(state: State) -> State {
  case state.clipboard {
    [] -> set_status(state, "Clipboard is empty")
    clipboard ->
      case active_module(state) {
        Error(error) -> set_status(state, error)
        Ok(module) -> {
          let root = campy_design.freeze(module.form.view)
          let #(parent_id, start) = paste_target(root, state.selection)

          let #(view, ids, _existing, _next) =
            list.fold(
              clipboard,
              #(root, [], campy_view.ids(root), start),
              fn(acc, original) {
                let #(view, ids, existing, next) = acc
                let #(clone, existing) = clone_tree(original, existing)
                let clone = offset_origin(clone, 16)
                let index =
                  int.min(next, campy_design.child_count(view, parent_id))

                case campy_design.insert_child(view, parent_id, index, clone) {
                  Ok(view) -> #(
                    view,
                    list.append(ids, [clone.id]),
                    existing,
                    next + 1,
                  )
                  Error(_) -> #(view, ids, existing, next)
                }
              },
            )

          state
          |> commit_view(module, view)
          |> select_controls(ids)
          |> set_status("Pasted " <> int.to_string(list.length(ids)))
        }
      }
  }
}

fn paste_target(root: Node, selection: List(String)) -> #(String, Int) {
  case selection {
    [id] ->
      case campy_design.find_node(root, id) {
        Some(node) ->
          case campy_catalog.accepts_children(node.kind) {
            True -> #(id, campy_design.child_count(root, id))
            False ->
              case campy_design.parent_of(root, id) {
                Some(parent) ->
                  case campy_design.index_of(root, parent, id) {
                    Ok(index) -> #(parent, index + 1)
                    Error(_) -> root_target(root)
                  }
                None -> root_target(root)
              }
          }
        None -> root_target(root)
      }
    _ -> root_target(root)
  }
}

fn root_target(root: Node) -> #(String, Int) {
  #(root.id, campy_design.child_count(root, root.id))
}

/// Duplicate the selection in place, offset a little so the copy is visible,
/// and select the copies.
pub fn duplicate_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let root = campy_design.freeze(module.form.view)
      let nodes = selected_top(root, state.selection)

      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let #(view, ids, _) =
            list.fold(
              nodes,
              #(root, [], campy_view.ids(root)),
              fn(acc, original) {
                let #(view, ids, existing) = acc
                let #(clone, existing) = clone_tree(original, existing)
                let clone = offset_origin(clone, 16)

                let #(parent, index) = case
                  campy_design.parent_of(view, original.id)
                {
                  Some(parent) ->
                    case campy_design.index_of(view, parent, original.id) {
                      Ok(index) -> #(parent, index + 1)
                      Error(_) -> root_target(view)
                    }
                  None -> root_target(view)
                }

                case campy_design.insert_child(view, parent, index, clone) {
                  Ok(view) -> #(view, list.append(ids, [clone.id]), existing)
                  Error(_) -> #(view, ids, existing)
                }
              },
            )

          state
          |> commit_view(module, view)
          |> select_controls(ids)
          |> set_status("Duplicated " <> int.to_string(list.length(ids)))
        }
      }
    }
  }
}

pub fn bring_to_front(state: State) -> State {
  reorder_selection(state, campy_design.bring_to_front)
}

pub fn send_to_back(state: State) -> State {
  reorder_selection(state, campy_design.send_to_back)
}

fn reorder_selection(
  state: State,
  operation: fn(Node, String) -> Result(Node, String),
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)
      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let view =
            list.fold(nodes, module.form.view, fn(view, node) {
              case operation(view, node.id) {
                Ok(updated) -> updated
                Error(_) -> view
              }
            })

          state
          |> commit_view(module, view)
          |> set_status("Reordered " <> int.to_string(list.length(nodes)))
        }
      }
    }
  }
}

/// Commit absolute rectangles for a finished drag. `reparent` carries
/// `#(control, new_container)` when a single move crossed a container edge;
/// the absolute rect is applied after the move, so the control stays exactly
/// where the pointer left it.
pub fn commit_geometry(
  state: State,
  items: List(#(String, campy_design.Rect)),
  reparent: Option(#(String, String)),
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let frozen = campy_design.freeze(module.form.view)
      let message = case reparent {
        None -> "Moved " <> int.to_string(list.length(items))
        Some(#(id, parent)) -> "Moved " <> id <> " to " <> parent
      }

      case reparent {
        None -> {
          // Resolve once, then store parent-relative rectangles. If a parent
          // is also moving, use its previewed absolute origin; otherwise use
          // the pre-edit frame. A group move keeps relative positions stable
          // even when a container and a child are both in the selection.
          let layout = campy_design.resolve(frozen)
          let desired = dict.from_list(items)
          let view =
            list.fold(items, frozen, fn(view, item) {
              let #(id, rect) = item
              let #(ox, oy) = parent_origin_for(layout, desired, id)
              campy_design.set_rect(
                view,
                id,
                campy_design.Rect(
                  x: rect.x - ox,
                  y: rect.y - oy,
                  w: rect.w,
                  h: rect.h,
                ),
              )
            })

          commit_view(state, module, view) |> set_status(message)
        }
        Some(#(id, parent)) -> {
          let view = case campy_design.reparent(frozen, id, parent) {
            Ok(updated) -> updated
            Error(_) -> frozen
          }

          let view =
            list.fold(items, view, fn(view, item) {
              let #(id, rect) = item
              campy_design.set_absolute_rect(view, id, rect)
            })

          commit_view(state, module, view) |> set_status(message)
        }
      }
    }
  }
}

/// Selected controls whose ancestors are not also selected. Deleting or
/// copying a container already covers its children.
fn selected_top(root: Node, ids: List(String)) -> List(Node) {
  list.filter_map(ids, fn(id) {
    case campy_design.find_node(root, id) {
      None -> Error(Nil)
      Some(node) ->
        case
          list.any(ids, fn(other) {
            other != id && campy_design.is_within(root, other, id)
          })
        {
          True -> Error(Nil)
          False -> Ok(node)
        }
    }
  })
}

/// Deep copy with fresh, globally unique ids. Keys are dropped because two
/// copies in the same parent must not share a reconciliation key.
fn clone_tree(node: Node, existing: List(String)) -> #(Node, List(String)) {
  let id = fresh_id(existing, node.kind)

  let #(children, existing) =
    list.fold(node.children, #([], [id, ..existing]), fn(acc, child) {
      let #(children, existing) = acc
      let #(clone, existing) = clone_tree(child, existing)
      #(list.append(children, [clone]), existing)
    })

  #(
    campy_view.Node(
      kind: node.kind,
      id: id,
      key: None,
      props: node.props,
      events: node.events,
      children: children,
      extra: node.extra,
    ),
    existing,
  )
}

fn fresh_id(existing: List(String), kind: String) -> String {
  let prefix = kind <> "_"

  let highest =
    list.fold(existing, 0, fn(highest, id) {
      case string.starts_with(id, prefix) {
        True ->
          case int.parse(string.drop_start(id, string.length(prefix))) {
            Ok(number) -> int.max(highest, number)
            Error(_) -> highest
          }
        False -> highest
      }
    })

  prefix <> int.to_string(highest + 1)
}

fn parent_origin_for(
  layout: campy_design.Layout,
  desired: dict.Dict(String, campy_design.Rect),
  id: String,
) -> #(Int, Int) {
  case campy_design.placed(layout, id) {
    Some(placed) ->
      case placed.parent {
        Some(parent_id) ->
          case dict.get(desired, parent_id) {
            Ok(rect) -> #(rect.x, rect.y)
            Error(_) -> campy_design.parent_origin_in(layout, id)
          }
        None -> #(0, 0)
      }
    None -> #(0, 0)
  }
}

fn offset_origin(node: Node, amount: Int) -> Node {
  let x = int.max(0, campy_design.int_prop(node, "x", 0) + amount)
  let y = int.max(0, campy_design.int_prop(node, "y", 0) + amount)

  node
  |> upsert("x", VInt(x))
  |> upsert("y", VInt(y))
}

fn upsert(node: Node, name: String, value: campy_view.Value) -> Node {
  let props = list.filter(node.props, fn(prop) { prop.0 != name })
  campy_view.with_props(node, list.append(props, [#(name, value)]))
}

pub fn update(state: State, command: Command) -> State {
  case command {
    OpenModule(slug) ->
      case open_module(state, slug) {
        Ok(state) -> state
        Error(error) -> set_status(state, error)
      }
    CloseModule(slug) -> close_module(state, slug)
    SelectControls(ids) -> select_controls(state, ids)
    Commit(project) -> commit(state, project)
    Undo -> undo(state)
    Redo -> redo(state)
    Log(line) -> log(state, line)
    SetStatus(text) -> set_status(state, text)
    ToggleCodeView -> toggle_code_view(state)
    Arm(kind) -> arm(state, kind)
    Disarm -> disarm(state)
    PlaceWidget(kind, x, y, w, h) -> place_widget(state, kind, x, y, w, h)
    CopySelection -> copy_selection(state)
    CutSelection -> cut_selection(state)
    Paste -> paste(state)
    DuplicateSelection -> duplicate_selection(state)
    DeleteSelection -> delete_selection(state)
    BringToFront -> bring_to_front(state)
    SendToBack -> send_to_back(state)
    CommitGeometry(items, reparent) -> commit_geometry(state, items, reparent)
  }
}

/// Console lines as one block, newest last, for a text pane.
pub fn console_text(state: State) -> String {
  state.console
  |> list.reverse
  |> list.intersperse("\n")
  |> list.fold("", fn(acc, line) { acc <> line })
}

/// A compact status line: active module, selection count, undo depth.
pub fn status_line(state: State) -> String {
  let module = case state.active {
    Some(slug) -> slug
    None -> "—"
  }
  let selection = int.to_string(list.length(state.selection))
  let history = int.to_string(list.length(state.undo))
  module <> "  sel:" <> selection <> "  undo:" <> history
}
