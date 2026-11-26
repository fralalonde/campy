import campy_bridge as bridge
import campy_ccl
import campy_form.{type Control, type Form, type Kind}
import campy_form/project.{type Module, type Project}
import campy_form/workspace.{type Workspace}
import campy_ide/shell
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Tab {
  Properties
  Events
}

// One row of the code editor's completion popup.
pub type Completion {
  Completion(label: String, detail: String, insert: String)
}

// The in-app file browser: used for every file operation (open, save as,
// picture and icon picking) so the filesystem is browsable even where no
// native dialog exists. `mode` is the Popup kind that accepts the result.
pub type Browser {
  Browser(mode: Popup, dir: String, name: String, entries: List(BrowserEntry))
}

pub type BrowserEntry {
  BrowserEntry(name: String, is_dir: Bool)
}

// Which editor the centre pane shows for the active module.
pub type ModuleView {
  FormView
  CodeView
}

// Highlighted code view vs. the focused handler editor.
pub type Editor {
  View
  Edit
}

pub type Popup {
  NoPopup
  OpenFile
  SaveAs
  PickPicture
  PickProjectIcon
}

pub type Scheme {
  Dark
  Light
  Solarized
}

pub type Clipboard {
  Clipboard(
    controls: List(Control),
    parents: List(#(String, String)),
    aligns: List(#(String, campy_form.Align)),
    layouts: List(#(String, campy_form.Layout)),
    borders: List(#(String, Int)),
    transparencies: List(#(String, Int)),
    colors: List(#(String, String)),
  )
}

pub type Preview {
  Preview(session: bridge.Session, id: Int, module: String, generation: Int)
}

// The designer's pointer gesture, driven by the canvas surface's raw
// `pointer:<id>:<phase>` events. Coordinates are form-local (the canvas and
// module-window offsets are subtracted by the loop).
pub type Gesture {
  Idle
  /// A button is down on `target` ("" = the canvas background) and the pointer
  /// has not moved past the drag threshold yet.
  Pressing(press: #(Int, Int), target: String)
  /// Dragging the selection; `last` is the previous move point.
  Moving(last: #(Int, Int))
  /// Dragging a marquee from `origin` (state `rect` holds its live size).
  Marqueing(origin: #(Int, Int))
  /// Dragging a pending palette control to its placement rectangle.
  Placing(origin: #(Int, Int))
  /// Dragging the module window by its title bar.
  MovingWindow(last: #(Int, Int))
  /// Dragging one edge (or corner) of the primary selection or the window.
  Resizing(mode: String, last: #(Int, Int), window: Bool)
}

pub type Editing {
  Editing(text: String, range: #(Int, Int))
}

// A global undo entry. Only the document plus the editing context is stored;
// ephemeral things (preview session, dialogs, clipboard, settings) stay live.
pub type History {
  History(
    project: Project,
    active: String,
    opened: List(String),
    view: ModuleView,
    selected: Option(String),
    selection: List(String),
    tab: Tab,
    active_handler: Option(String),
    highlight: Option(#(Int, Int)),
  )
}

pub type State {
  State(
    project: Project,
    workspace: Workspace,
    active: String,
    opened: List(String),
    view: ModuleView,
    selected: Option(String),
    selection: List(String),
    /// The components a marquee currently *would* select, while the button is
    /// still down. Drawn as outlines and handles so the frame shows its
    /// contents as it grows, without touching the real selection.
    preview_selection: List(String),
    tab: Tab,
    editor: Editor,
    active_handler: Option(String),
    highlight: Option(#(Int, Int)),
    editing: Option(Editing),
    /// Every running app window, one per module. A project's app and any of
    /// its modules can run at the same time; each preview owns its session.
    previews: List(Preview),
    popup: Popup,
    undo: List(History),
    redo: List(History),
    merge_undo: Bool,
    /// The document when the current gesture began. A drag or resize records
    /// one undo step — this state — when the button is released, not one per
    /// pointer move.
    gesture_base: Option(History),
    /// Which property field is mid-typing (`<control>:<field>`), so a run of
    /// keystrokes in one field is one undo step. Cleared by any other change.
    edit_run: Option(String),
    clipboard: Option(Clipboard),
    font: String,
    font_size: Int,
    scheme: Scheme,
    settings_open: Bool,
    selected_project: Bool,
    project_dialog_open: Bool,
    context_open: Bool,
    context_x: Int,
    context_y: Int,
    context_align: Bool,
    agent_open: Bool,
    mcp_enabled: Bool,
    mcp_port: Int,
    mcp_status: String,
    hints: Bool,
    pending_kind: Option(Kind),
    drop_active: Bool,
    drop_candidate: String,
    drop_x: Int,
    drop_y: Int,
    drag_control: Option(String),
    rect: #(Int, Int, Int, Int),
    console: List(String),
    window_positions: List(#(String, #(Int, Int))),
    caret: #(Int, Int),
    completions: List(Completion),
    completion_index: Int,
    completions_requested: Bool,
    diagnostics: List(#(Int, Int, String)),
    lsp_uri: String,
    code_version: Int,
    browser: Option(Browser),
    code_jump: Option(Int),
    code_jump_nonce: Int,
    nav_context_open: Bool,
    nav_kind: String,
    nav_id: String,
    gesture: Gesture,
    last_pointer: #(Int, Int),
    /// The previous click: which component and when, for double-click.
    last_click: Option(#(String, Int)),
    status: String,
    /// The window's CSS size as the renderer last reported it: the shell
    /// layout stretches to it and pointer coordinates are mapped with it.
    window_size: #(Int, Int),
    /// The status line's text before a hover hint replaced it, so leaving the
    /// control restores the message rather than clearing it.
    hover_status: Option(String),
  )
}

pub fn initial(project: Project) -> State {
  initial_workspace(workspace.new(project))
}

// A hot reload (F6) swaps in new beams while the running process still holds
// state built by the previous code. When the project format version moved on,
// the in-memory document is stale — its records may not even have the fields
// the new code reads — so reload the workspace from disk instead. This lives
// in `state` (not `campy_ide`) on purpose: the previous `campy_ide` module may
// still be the one executing after the beams swap, and calling through this
// module boundary runs the *current* migration logic with the *current*
// `project.version` constant.
pub fn ensure_current_format(
  state: State,
  load_workspace: fn() -> Workspace,
) -> State {
  case state.project.version < project.version {
    False -> state
    True ->
      initial_workspace(load_workspace())
      |> set_status("Project format upgraded; workspace reloaded")
  }
}

pub fn initial_workspace(workspace: Workspace) -> State {
  let fallback = project.campy()
  let project = case workspace.active_project(workspace) {
    Some(active) -> active
    None -> fallback
  }
  let active = case project.modules {
    [module, ..] -> module.id
    [] -> ""
  }
  State(
    project: project,
    workspace: workspace,
    active: active,
    opened: case active {
      "" -> []
      id -> [id]
    },
    view: FormView,
    selected: None,
    selection: [],
    preview_selection: [],
    tab: Properties,
    editor: View,
    active_handler: None,
    highlight: None,
    editing: None,
    previews: [],
    popup: NoPopup,
    undo: [],
    redo: [],
    merge_undo: False,
    gesture_base: None,
    edit_run: None,
    clipboard: None,
    font: "monospace",
    font_size: 13,
    scheme: Dark,
    settings_open: False,
    selected_project: False,
    project_dialog_open: False,
    context_open: False,
    context_x: 0,
    context_y: 0,
    context_align: False,
    agent_open: False,
    mcp_enabled: False,
    mcp_port: 7817,
    mcp_status: "Stopped",
    hints: True,
    pending_kind: None,
    drop_active: False,
    drop_candidate: "",
    drop_x: 0,
    drop_y: 0,
    drag_control: None,
    rect: #(0, 0, 0, 0),
    console: [],
    window_positions: [],
    caret: #(0, 0),
    completions: [],
    completion_index: 0,
    completions_requested: False,
    diagnostics: [],
    lsp_uri: "",
    code_version: 1,
    browser: None,
    code_jump: None,
    code_jump_nonce: 0,
    nav_context_open: False,
    nav_kind: "",
    nav_id: "",
    gesture: Idle,
    last_pointer: #(0, 0),
    last_click: None,
    status: "Ready",
    window_size: #(shell.window_width, shell.window_height),
    hover_status: None,
  )
}

fn history(state: State) -> History {
  History(
    state.project,
    state.active,
    state.opened,
    state.view,
    state.selected,
    state.selection,
    state.tab,
    state.active_handler,
    state.highlight,
  )
}

fn restore(state: State, past: History) -> State {
  State(
    ..state,
    project: past.project,
    active: past.active,
    opened: past.opened,
    view: past.view,
    selected: past.selected,
    selection: past.selection,
    tab: past.tab,
    active_handler: past.active_handler,
    highlight: past.highlight,
    editing: None,
    editor: View,
  )
}

// Record one undo step when the document (or selection context) changed.
fn commit(state: State, next: State) -> State {
  let before = history(state)
  case before == history(next) {
    True -> State(..next, undo: state.undo, redo: state.redo, merge_undo: False)
    False ->
      case state.merge_undo {
        // The second half of a drag/resize joins the first half's undo step.
        True ->
          State(..next, undo: state.undo, redo: state.redo, merge_undo: False)
        False ->
          State(
            ..next,
            undo: [before, ..state.undo],
            redo: [],
            merge_undo: False,
            edit_run: None,
          )
      }
  }
}

pub fn can_undo(state: State) -> Bool {
  !list.is_empty(state.undo)
}

pub fn can_redo(state: State) -> Bool {
  !list.is_empty(state.redo)
}

pub fn undo(state: State) -> State {
  case state.undo {
    [] -> status(state, "Nothing to undo")
    [previous, ..rest] -> {
      let next = restore(state, previous)
      State(
        ..next,
        undo: rest,
        redo: [history(state), ..state.redo],
        merge_undo: False,
        edit_run: None,
        status: "Undo",
      )
    }
  }
}

pub fn redo(state: State) -> State {
  case state.redo {
    [] -> status(state, "Nothing to redo")
    [future, ..rest] -> {
      let next = restore(state, future)
      State(
        ..next,
        undo: [history(state), ..state.undo],
        redo: rest,
        merge_undo: False,
        edit_run: None,
        status: "Redo",
      )
    }
  }
}

fn with_project(state: State, workspace: Workspace, project: Project) -> State {
  let base = initial_workspace(workspace.switch(workspace, project.path))
  State(
    ..base,
    font: state.font,
    font_size: state.font_size,
    scheme: state.scheme,
    clipboard: state.clipboard,
    previews: state.previews,
    selected_project: True,
    caret: state.caret,
    diagnostics: state.diagnostics,
    status: "Project · " <> project.title,
  )
}

pub fn switch_project(state: State, path: String) -> State {
  case workspace.find(state.workspace, path) {
    None -> status(state, "Project not found in the workspace")
    Some(target) if target.path == state.project.path ->
      State(
        ..state,
        selected: None,
        selection: [],
        selected_project: True,
        active_handler: None,
        highlight: None,
        editing: None,
        status: "Project · " <> target.title,
      )
    Some(target) -> {
      let ws = workspace.update_active(state.workspace, state.project)
      with_project(state, ws, target)
      |> status("Switched to " <> target.title)
    }
  }
}

pub fn create_project(state: State) -> State {
  let ws = workspace.update_active(state.workspace, state.project)
  let number = workspace.next_project_number(ws)
  let path = "projects/project-" <> int.to_string(number) <> ".campy"
  let created = project.new_project("Project " <> int.to_string(number), path)
  let ws = workspace.upsert(ws, created)
  with_project(state, ws, created)
  |> status("Created " <> created.title)
}

pub fn delete_active_project(state: State) -> State {
  let ws = workspace.update_active(state.workspace, state.project)
  case workspace.count(ws) <= 1 {
    True -> status(state, "A workspace needs at least one project")
    False -> {
      let removed = workspace.remove(ws, state.project.path)
      case workspace.active_project(removed) {
        Some(next) ->
          with_project(state, removed, next)
          |> status("Removed " <> state.project.title <> " from the workspace")
        None -> state
      }
    }
  }
}

pub fn open_project(state: State, loaded: Project) -> State {
  let ws = workspace.update_active(state.workspace, state.project)
  case workspace.find(ws, loaded.path) {
    Some(existing) ->
      with_project(state, ws, existing)
      |> status("Switched to " <> existing.title)
    None -> {
      let ws = workspace.upsert(ws, loaded)
      with_project(state, ws, loaded)
      |> status("Opened " <> loaded.title)
    }
  }
}

pub fn active_module(state: State) -> Option(Module) {
  project.find_module(state.project, state.active)
}

pub fn active_form(state: State) -> Option(Form) {
  case active_module(state) {
    Some(module) -> Some(module.form)
    None -> None
  }
}

pub fn active_name(state: State) -> String {
  case active_module(state) {
    Some(module) -> module.name
    None -> "No module"
  }
}

fn update_active_module(state: State, change: fn(Module) -> Module) -> State {
  case active_module(state) {
    Some(module) ->
      State(
        ..state,
        project: project.update_module(state.project, change(module)),
      )
    None -> state
  }
}

fn update_active_form(state: State, change: fn(Form) -> Form) -> State {
  update_active_module(state, fn(module) {
    project.Module(..module, form: change(module.form))
  })
}

pub fn open_module(state: State, id: String) -> State {
  case project.find_module(state.project, id) {
    None -> status(state, "Unknown module")
    Some(module) -> {
      // Opening appends the tab; an already-open tab never moves.
      let opened = case list.contains(state.opened, id) {
        True -> state.opened
        False -> list.append(state.opened, [id])
      }
      State(
        ..state,
        active: id,
        opened: opened,
        view: FormView,
        selected: None,
        selection: [],
        selected_project: False,
        active_handler: None,
        highlight: None,
        editing: None,
        editor: View,
        completions: [],
        completion_index: 0,
        status: "Opened " <> module.name,
      )
    }
  }
}

// Switching tab keeps the current Form/Code view and the tab order; only the
// module changes.
pub fn activate_module(state: State, id: String) -> State {
  case project.find_module(state.project, id) {
    None -> state
    Some(module) ->
      State(
        ..state,
        active: id,
        selected: None,
        selection: [],
        selected_project: False,
        active_handler: None,
        highlight: None,
        editing: None,
        editor: View,
        completions: [],
        completion_index: 0,
        status: "Switched to " <> module.name,
      )
  }
}

pub fn close_module(state: State, id: String) -> State {
  case list.filter(state.opened, fn(open) { open != id }) {
    [] -> status(state, "Cannot close the last tab")
    remaining ->
      case state.active == id {
        // Closing the active tab removes the module from the workspace
        // index; committed so undo restores it.
        False ->
          commit(state, State(..state, opened: remaining, status: "Closed tab"))
        True -> remove_module(state, id, remaining, "Closed tab")
      }
  }
}

// Delete a module from the project (context menu), regardless of whether it
// is the active tab. Committed so undo restores the module.
pub fn delete_module(state: State, id: String) -> State {
  case list.filter(state.opened, fn(open) { open != id }) {
    [] -> status(state, "Cannot delete the last module")
    remaining ->
      case list.find(state.project.modules, fn(module) { module.id == id }) {
        Error(_) -> state
        Ok(module) ->
          remove_module(
            state,
            id,
            remaining,
            "Deleted " <> module.name <> " (undo restores it)",
          )
      }
  }
}

fn remove_module(
  state: State,
  id: String,
  remaining: List(String),
  note: String,
) -> State {
  let next = case remaining {
    [first, ..] -> first
    [] -> ""
  }
  let kept = list.filter(state.project.modules, fn(module) { module.id != id })
  let project = project.Project(..state.project, modules: kept)
  let was_active = state.active == id
  commit(
    state,
    State(
      ..state,
      project: project,
      opened: remaining,
      active: case was_active {
        True -> next
        False -> state.active
      },
      view: FormView,
      selected: None,
      selection: [],
      active_handler: None,
      highlight: None,
      editing: None,
      editor: View,
      status: note,
    ),
  )
}

pub fn new_module(state: State) -> State {
  let suffix = next_module_suffix(state.project.modules, 1)
  let id = "module-" <> int.to_string(suffix)
  let module =
    project.Module(
      id,
      "Module " <> int.to_string(suffix),
      campy_form.new_form(),
      project.Embedded(campy_form.default_source()),
    )
  let next = State(..state, project: project.add_module(state.project, module))
  commit(
    state,
    open_module(next, id)
      |> status("Added Module " <> int.to_string(suffix)),
  )
}

fn next_module_suffix(modules: List(Module), start: Int) -> Int {
  let id = "module-" <> int.to_string(start)
  case list.any(modules, fn(module) { module.id == id }) {
    True -> next_module_suffix(modules, start + 1)
    False -> start
  }
}

pub fn set_view(state: State, view: ModuleView) -> State {
  State(..state, view: view)
}

// The single top-right button switches the editor between the form and the
// handler code.
pub fn toggle_view(state: State) -> State {
  case state.view {
    FormView -> State(..state, view: CodeView)
    CodeView -> State(..state, view: FormView, editor: View, editing: None)
  }
}

pub fn add(state: State, kind: Kind) -> State {
  case active_form(state) {
    None -> status(state, "Open a module first")
    Some(form) -> {
      let #(form, control) =
        campy_form.add_control(form, kind, adoption_target(state))
      let next = update_active_form(state, fn(_) { form })
      commit(
        state,
        State(
          ..next,
          selected: Some(control.id),
          selection: [control.id],
          selected_project: False,
          tab: Properties,
          status: "Added " <> campy_form.kind_label(kind),
        ),
      )
    }
  }
}

// New and pasted controls are adopted by the selected component when it accepts
// children, otherwise by its first accepting ancestor, otherwise by the window.
pub fn adoption_target(state: State) -> String {
  case selected_control(state) {
    None -> ""
    Some(control) -> accepting_ancestor(state, control)
  }
}

fn accepting_ancestor(state: State, control: Control) -> String {
  case campy_form.accepts_children(control.kind) {
    True -> control.id
    False ->
      case active_form(state) {
        None -> ""
        Some(form) ->
          case campy_form.parent_of(form, control.id) {
            "" -> ""
            parent ->
              case campy_form.find_control(form, parent) {
                Some(above) -> accepting_ancestor(state, above)
                None -> ""
              }
          }
      }
  }
}

pub fn select(state: State, id: String) -> State {
  case id == "" {
    True ->
      State(
        ..state,
        selected: None,
        selection: [],
        selected_project: False,
        active_handler: None,
        highlight: None,
        editing: None,
      )
    False ->
      case active_form(state) {
        Some(form) ->
          case campy_form.find_control(form, id) {
            Some(_) ->
              State(
                ..state,
                selected: Some(id),
                selection: [id],
                selected_project: False,
                tab: state.tab,
                active_handler: None,
                highlight: None,
                editing: None,
                editor: View,
              )
            None -> state
          }
        None -> state
      }
  }
}

// Ctrl-click toggles membership; the last added control is the inspector primary.
pub fn toggle_select(state: State, id: String) -> State {
  case active_form(state) {
    None -> state
    Some(form) ->
      case campy_form.find_control(form, id) {
        None -> state
        Some(_) -> {
          let selected = list.contains(state.selection, id)
          case selected {
            True -> {
              let rest = list.filter(state.selection, fn(item) { item != id })
              let primary = case list.reverse(rest) {
                [first, ..] -> Some(first)
                [] -> None
              }
              State(
                ..state,
                selected: primary,
                selection: rest,
                active_handler: None,
                highlight: None,
                editing: None,
                status: "Selected " <> int.to_string(list.length(rest)),
              )
            }
            False ->
              State(
                ..state,
                selected: Some(id),
                selection: list.append(state.selection, [id]),
                selected_project: False,
                tab: state.tab,
                active_handler: None,
                highlight: None,
                editing: None,
                status: "Selected "
                  <> int.to_string(list.length(state.selection) + 1),
              )
          }
        }
      }
  }
}

pub fn set_tab(state: State, tab: Tab) -> State {
  State(..state, tab: tab)
}

pub fn delete_selected(state: State) -> State {
  case active_form(state) {
    None -> status(state, "Select a control to delete")
    Some(form) -> {
      let ids = selection_subtree_ids(state, form)
      case ids {
        [] -> status(state, "Select a control to delete")
        _ -> {
          let next =
            update_active_form(state, fn(_) {
              campy_form.remove_controls(form, ids)
            })
          let count = list.length(state.selection)
          commit(
            state,
            State(
              ..next,
              selected: None,
              selection: [],
              active_handler: None,
              highlight: None,
              editing: None,
              status: case count {
                1 -> "Component deleted"
                _ -> int.to_string(count) <> " components deleted"
              },
            ),
          )
        }
      }
    }
  }
}

pub fn commit_field(state: State, field: String, value: String) -> State {
  let next = case state.selected, active_form(state) {
    Some(id), Some(form) -> commit_control_field(state, form, id, field, value)
    None, Some(form) -> commit_form_field(state, form, field, value)
    _, _ -> status(state, "Open a module first")
  }
  // A field reports every keystroke. The first one opens an undo step; the rest
  // of the run joins it, so Ctrl+Z puts the whole typed value back rather than
  // walking it backwards a letter at a time. A rejected value (an invalid or
  // duplicate name) changes nothing and leaves the run as it was.
  case history(state) == history(next) {
    True -> next
    False -> {
      let key = case state.selected {
        Some(id) -> id <> ":" <> field
        None -> "window:" <> field
      }
      case state.edit_run == Some(key) {
        True -> State(..next, edit_run: Some(key), redo: [], merge_undo: False)
        False -> State(..commit(state, next), edit_run: Some(key))
      }
    }
  }
}

fn commit_control_field(
  state: State,
  form: Form,
  id: String,
  field: String,
  value: String,
) -> State {
  case field {
    "name" ->
      case campy_form.valid_name(value) && !name_taken(form, id, value) {
        False -> status(state, "Invalid or duplicate control name")
        True ->
          change_control(state, form, id, fn(control) {
            campy_form.Control(..control, name: value)
          })
      }
    "text" ->
      change_control(state, form, id, fn(control) {
        campy_form.Control(..control, text: value)
      })
    "border" ->
      case campy_form.find_control(form, id) {
        Some(control) ->
          case campy_form.accepts_children(control.kind) {
            True -> commit_border(state, id, value)
            False -> status(state, "Border applies to containers")
          }
        None -> state
      }
    "parent" -> set_selected_parent(state, value)
    "transparency" ->
      case campy_form.find_control(form, id) {
        Some(control) ->
          case control.kind {
            campy_form.Picture -> commit_transparency(state, id, value)
            _ -> status(state, "Transparency applies to pictures")
          }
        None -> state
      }
    "x" ->
      update_axis(state, form, id, field, value, 0, campy_form.max_coordinate)
    "y" ->
      update_axis(state, form, id, field, value, 0, campy_form.max_coordinate)
    "w" ->
      update_axis(state, form, id, field, value, 1, campy_form.max_coordinate)
    "h" ->
      update_axis(state, form, id, field, value, 1, campy_form.max_coordinate)
    _ -> state
  }
}

fn name_taken(form: Form, id: String, name: String) -> Bool {
  form.controls
  |> list.any(fn(control) { control.id != id && control.name == name })
}

fn change_control(
  state: State,
  form: Form,
  id: String,
  change: fn(Control) -> Control,
) -> State {
  update_active_form(state, fn(_) {
    campy_form.update_selected(form, id, change)
  })
}

fn update_axis(
  state: State,
  form: Form,
  id: String,
  field: String,
  value: String,
  min: Int,
  max: Int,
) -> State {
  case int.parse(value) {
    Error(_) -> status(state, "Enter a whole number")
    Ok(number) ->
      case number >= min && number <= max {
        False ->
          status(
            state,
            "Value must be between "
              <> int.to_string(min)
              <> " and "
              <> int.to_string(max),
          )
        True ->
          change_control(state, form, id, fn(control) {
            case field {
              "x" -> campy_form.Control(..control, x: number)
              "y" -> campy_form.Control(..control, y: number)
              "w" -> campy_form.Control(..control, width: number)
              "h" -> campy_form.Control(..control, height: number)
              _ -> control
            }
          })
      }
  }
}

fn commit_border(state: State, parent_id: String, value: String) -> State {
  case int.parse(value) {
    Error(_) -> status(state, "Border must be a whole number")
    Ok(number) ->
      case number >= 0 && number <= 512 {
        True -> {
          let next =
            update_active_form(state, fn(form) {
              campy_form.set_border_for(form, parent_id, number)
            })
          status(next, "Border set to " <> int.to_string(number) <> "px")
        }
        False -> status(state, "Border must be between 0 and 512")
      }
  }
}

fn commit_transparency(state: State, id: String, value: String) -> State {
  case int.parse(value) {
    Error(_) -> status(state, "Transparency must be a whole number")
    Ok(number) ->
      case number >= 0 && number <= 100 {
        True -> {
          let next =
            update_active_form(state, fn(form) {
              campy_form.set_transparency_for(form, id, number)
            })
          status(next, "Transparency set to " <> int.to_string(number) <> "%")
        }
        False -> status(state, "Transparency must be between 0 and 100")
      }
  }
}

// Z-order for overlapping siblings follows the controls list: render_controls
// draws later entries above earlier ones. Moving reorders within the whole
// form; a control's subtree keeps rendering relative to its own parent.
pub fn bring_to_front(state: State) -> State {
  reorder_selection(state, True)
}

pub fn send_to_back(state: State) -> State {
  reorder_selection(state, False)
}

fn reorder_selection(state: State, front: Bool) -> State {
  case active_form(state) {
    None -> state
    Some(form) -> {
      let roots = selection_roots(state, form)
      case roots {
        [] -> status(state, "Select a component to reorder")
        _ -> {
          let next =
            update_active_form(state, fn(current) {
              case front {
                True -> campy_form.bring_to_front(current, roots)
                False -> campy_form.send_to_back(current, roots)
              }
            })
          commit(
            state,
            status(next, case front {
              True -> "Brought to front"
              False -> "Moved to back"
            }),
          )
        }
      }
    }
  }
}

fn commit_form_field(
  state: State,
  form: Form,
  field: String,
  value: String,
) -> State {
  case field {
    "title" ->
      update_active_form(state, fn(_) { campy_form.Form(..form, title: value) })
    "width" -> update_form_size(state, form, value, True)
    "height" -> update_form_size(state, form, value, False)
    "layout" ->
      update_active_form(state, fn(_) {
        campy_form.set_layout_for(form, "", layout_from_name(value))
      })
    "border" -> commit_border(state, "", value)
    _ -> state
  }
}

fn update_form_size(
  state: State,
  form: Form,
  value: String,
  is_width: Bool,
) -> State {
  case int.parse(value) {
    Ok(number) if number > 0 && number <= campy_form.max_form_size ->
      update_active_form(state, fn(_) {
        case is_width {
          True -> campy_form.Form(..form, width: number)
          False -> campy_form.Form(..form, height: number)
        }
      })
    _ -> status(state, "Form size must be between 1 and 4096")
  }
}

pub fn toggle_field(state: State, field: String, value: Bool) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        case field {
          "enabled" -> campy_form.Control(..control, enabled: value)
          "visible" -> campy_form.Control(..control, visible: value)
          _ -> control
        }
      })
    _, _ -> state
  }
}

// Cursor gestures commit once on release; the UI tracks the drag locally and
// sends X then Y (or W then H), which share one undo entry.
pub fn begin_gesture(state: State) -> State {
  State(
    ..state,
    merge_undo: False,
    edit_run: None,
    gesture_base: Some(history(state)),
  )
}

/// Ends a gesture and records it as one undo step: what the document was when
/// the button went down, and everything the gesture did to it, is one entry.
pub fn end_gesture(state: State) -> State {
  // A drag ends by dropping: the container under the pointer adopts it, or the
  // window when it is over none. Only a drag carries a target (`drag_control`),
  // so a resize never reparents.
  let state = case state.drag_control {
    Some(_) -> reparent_after_drop(state)
    None -> state
  }
  let state = case state.gesture_base {
    Some(base) ->
      case base == history(state) {
        True -> state
        False -> State(..state, undo: [base, ..state.undo], redo: [])
      }
    None -> state
  }
  State(
    ..state,
    gesture_base: None,
    merge_undo: False,
    drop_active: False,
    drop_candidate: "",
    drag_control: None,
  )
}

// A change while a gesture is in flight: the document moves, but the undo
// entry is the gesture's, recorded on release.
fn gesture_change(state: State, next: State) -> State {
  State(
    ..next,
    undo: state.undo,
    redo: state.redo,
    merge_undo: False,
    edit_run: None,
  )
}

// Move the selection (including each root's subtree) by a delta.
//
// The block moves as one: the delta is clamped by the *selection's outline*,
// not by each component, so the first component to reach an edge stops them
// all instead of the block tearing apart.
fn move_selected_raw(state: State, dx: Int, dy: Int) -> State {
  case state.selection, active_form(state) {
    [_, ..], Some(form) -> {
      let ids = selection_subtree_ids(state, form)
      let #(dx, dy) = case union_bounds(form, ids) {
        Some(#(left, top, width, height)) -> #(
          int.clamp(dx, -left, campy_form.max_coordinate - left - width),
          int.clamp(dy, -top, campy_form.max_coordinate - top - height),
        )
        None -> #(dx, dy)
      }
      let next =
        list.fold(ids, form, fn(acc, id) {
          campy_form.update_selected(acc, id, fn(control) {
            campy_form.Control(..control, x: control.x + dx, y: control.y + dy)
          })
        })
      update_active_form(state, fn(_) { next })
    }
    _, _ -> state
  }
}

/// The container the current drag would drop into and its rectangle, in form
/// coordinates. `#(active, x, y, w, h)`; an empty container id is the window.
pub fn drop_target_rect(state: State) -> #(Bool, Int, Int, Int, Int) {
  case state.drop_active, active_form(state) {
    True, Some(form) ->
      case state.drop_candidate {
        "" -> #(True, 0, 0, form.width, form.height)
        id ->
          case campy_form.find_control(form, id) {
            Some(container) -> {
              let #(x, y, w, h) = campy_form.bounds(form, container)
              #(True, x, y, w, h)
            }
            None -> #(False, 0, 0, 0, 0)
          }
      }
    _, _ -> #(False, 0, 0, 0, 0)
  }
}

/// The containers a control could be moved into: the window, then every
/// container that is not the control itself or inside it. `#(id, label)`.
pub fn parent_choices(state: State, id: String) -> List(#(String, String)) {
  case active_form(state) {
    None -> [#("", "(window)")]
    Some(form) ->
      list.append(
        [#("", "(window)")],
        form.controls
          |> list.filter(fn(control) {
            control.kind != campy_form.Label
            && campy_form.accepts_children(control.kind)
            && control.id != id
            && !list.contains(campy_form.descendant_ids(form, id), control.id)
          })
          |> list.map(fn(control) { #(control.id, control.name) }),
      )
  }
}

/// Reparents the selection from the inspector's Parent row. The label is the
/// container's name ("(window)" for the root).
pub fn set_selected_parent(state: State, label: String) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> {
      let parent = case label {
        "" | "(window)" -> ""
        name ->
          case list.find(form.controls, fn(control) { control.name == name }) {
            Ok(control) -> control.id
            Error(_) -> ""
          }
      }
      let next = campy_form.set_parent(form, id, parent)
      let next = update_active_form(state, fn(_) { next })
      commit(
        state,
        State(..next, status: case parent {
          "" -> "Moved " <> id <> " to the window"
          _ -> "Moved " <> id <> " into " <> label
        }),
      )
    }
    _, _ -> state
  }
}

/// The smallest rectangle around `ids`, in form coordinates. It is both the
/// block's allowed travel and its grab area.
pub fn union_bounds(
  form: Form,
  ids: List(String),
) -> Option(#(Int, Int, Int, Int)) {
  ids
  |> list.filter_map(fn(id) {
    case campy_form.find_control(form, id) {
      Some(control) -> Ok(campy_form.bounds(form, control))
      None -> Error(Nil)
    }
  })
  |> list.fold(None, fn(acc, box) {
    case acc {
      None -> Some(box)
      Some(#(left, top, width, height)) -> {
        let #(bx, by, bw, bh) = box
        let next_left = int.min(left, bx)
        let next_top = int.min(top, by)
        Some(#(
          next_left,
          next_top,
          int.max(left + width, bx + bw) - next_left,
          int.max(top + height, by + bh) - next_top,
        ))
      }
    }
  })
}

pub fn move_selected(state: State, dx: Int, dy: Int) -> State {
  commit(state, move_selected_raw(state, dx, dy))
}

pub fn move_gesture_x(state: State, dx: Int) -> State {
  gesture_change(state, move_selected_raw(state, dx, 0))
}

pub fn move_gesture_y(state: State, dy: Int) -> State {
  gesture_change(state, move_selected_raw(state, 0, dy))
}

// Dropping a control over a panel (or group box) adopts it. Dropping outside
// every container moves it back to the window root. This happens on release,
// not while the pointer moves: mid-drag reparenting changes the document under
// the gesture and makes the drop impossible to see coming.
fn reparent_after_drop(state: State) -> State {
  case active_form(state) {
    None -> state
    Some(form) -> {
      let roots = selection_roots(state, form)
      let #(next_form, labels) =
        list.fold(roots, #(form, []), fn(acc, id) {
          let #(current, labels) = acc
          case campy_form.find_control(current, id) {
            None -> #(current, labels)
            Some(control) -> {
              let target = drop_target_for(state, current, control)
              let next = campy_form.set_parent(current, id, target)
              let label = case target == "" {
                True -> "Moved to the window"
                False ->
                  case campy_form.find_control(next, target) {
                    Some(parent) -> "Adopted by " <> parent.name
                    None -> "Adopted"
                  }
              }
              #(next, [label, ..labels])
            }
          }
        })
      let next = update_active_form(state, fn(_) { next_form })
      State(..next, status: case labels {
        [label, ..] -> label
        [] -> "Moved"
      })
    }
  }
}

// A pointer drag reparents by where the cursor is released; moves without a
// gesture (programmatic moves, tests) fall back to the control's centre.
fn drop_target_for(state: State, form: Form, control: Control) -> String {
  case state.drag_control {
    Some(_) -> drop_target_at(form, control, state.drop_x, state.drop_y)
    None -> {
      let #(x, y, width, height) = campy_form.bounds(form, control)
      drop_target_at(form, control, x + width / 2, y + height / 2)
    }
  }
}

fn drop_target_at(form: Form, control: Control, cx: Int, cy: Int) -> String {
  campy_form.container_at_excluding(
    form,
    cx,
    cy,
    campy_form.subtree_ids(form, control.id),
  )
}

fn resize_selected_raw(state: State, dw: Int, dh: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        campy_form.Control(
          ..control,
          width: int.clamp(control.width + dw, 8, campy_form.max_coordinate),
          height: int.clamp(control.height + dh, 8, campy_form.max_coordinate),
        )
      })
    _, _ -> state
  }
}

pub fn resize_selected(state: State, dw: Int, dh: Int) -> State {
  commit(state, resize_selected_raw(state, dw, dh))
}

pub fn resize_gesture_w(state: State, dw: Int) -> State {
  gesture_change(state, resize_selected_raw(state, dw, 0))
}

pub fn resize_gesture_h(state: State, dh: Int) -> State {
  gesture_change(state, resize_selected_raw(state, 0, dh))
}

fn resize_left_raw(state: State, dx: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        let new_x = int.clamp(control.x + dx, 0, control.x + control.width - 8)
        campy_form.Control(
          ..control,
          x: new_x,
          width: control.width + control.x - new_x,
        )
      })
    _, _ -> state
  }
}

fn resize_right_raw(state: State, dx: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        campy_form.Control(
          ..control,
          width: int.clamp(control.width + dx, 8, campy_form.max_coordinate),
        )
      })
    _, _ -> state
  }
}

fn resize_top_raw(state: State, dy: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        let new_y = int.clamp(control.y + dy, 0, control.y + control.height - 8)
        campy_form.Control(
          ..control,
          y: new_y,
          height: control.height + control.y - new_y,
        )
      })
    _, _ -> state
  }
}

fn resize_bottom_raw(state: State, dy: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        campy_form.Control(
          ..control,
          height: int.clamp(control.height + dy, 8, campy_form.max_coordinate),
        )
      })
    _, _ -> state
  }
}

pub fn resize_left(state: State, dx: Int) -> State {
  gesture_change(state, resize_left_raw(state, dx))
}

pub fn resize_right(state: State, dx: Int) -> State {
  gesture_change(state, resize_right_raw(state, dx))
}

pub fn resize_top(state: State, dy: Int) -> State {
  gesture_change(state, resize_top_raw(state, dy))
}

pub fn resize_bottom(state: State, dy: Int) -> State {
  gesture_change(state, resize_bottom_raw(state, dy))
}

pub fn layout_from_name(name: String) -> campy_form.Layout {
  case name {
    "Column" -> campy_form.Column
    "Row" -> campy_form.Row
    _ -> campy_form.Free
  }
}

pub fn set_layout(state: State, layout: campy_form.Layout) -> State {
  case active_form(state) {
    Some(form) ->
      commit(
        state,
        update_active_form(state, fn(_) {
          campy_form.Form(..form, layout: layout)
        }),
      )
    None -> state
  }
}

pub fn set_container_layout(state: State, layout: campy_form.Layout) -> State {
  case selected_control(state), active_form(state) {
    Some(control), Some(_) ->
      case campy_form.accepts_children(control.kind) {
        True ->
          commit(
            state,
            update_active_form(state, fn(form) {
              campy_form.set_layout_for(form, control.id, layout)
            }),
          )
        False -> state
      }
    _, _ -> state
  }
}

pub fn set_align(state: State, align: campy_form.Align) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      commit(
        state,
        update_active_form(state, fn(_) {
          campy_form.set_align(form, id, align)
        }),
      )
    _, _ -> state
  }
}

pub fn selected_align(state: State) -> campy_form.Align {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> campy_form.align_of(form, id)
    _, _ -> campy_form.NoAlign
  }
}

pub fn align_from_name(name: String) -> campy_form.Align {
  case name {
    "Top" -> campy_form.Top
    "Bottom" -> campy_form.Bottom
    "Left" -> campy_form.Left
    "Right" -> campy_form.Right
    "Client" -> campy_form.Client
    "Fill" -> campy_form.Fill
    _ -> campy_form.NoAlign
  }
}

// Align the multi-selection: edges to the shared extreme, centres to the
// average ("center" puts the components in one column, "middle" in one row).
// Every root moves together with its subtree, as one undo step.
pub fn align_selection(state: State, kind: String) -> State {
  case active_form(state) {
    None -> state
    Some(form) -> {
      let roots = selection_roots(state, form)
      case list.length(roots) < 2 {
        True -> status(state, "Select at least two components to align")
        False -> {
          let rects =
            list.filter_map(roots, fn(id) {
              case campy_form.find_control(form, id) {
                Some(control) -> Ok(campy_form.bounds(form, control))
                None -> Error(Nil)
              }
            })
          case rects {
            [] -> state
            _ -> {
              let count = list.length(rects)
              let min_x = fold_rect(rects, campy_form.max_coordinate, 0)
              let max_right = fold_rect(rects, 0, 2)
              let min_y = fold_rect(rects, campy_form.max_coordinate, 1)
              let max_bottom = fold_rect(rects, 0, 3)
              let avg_cx =
                list.fold(rects, 0, fn(acc, rect) { acc + rect.0 + rect.2 / 2 })
                / count
              let avg_cy =
                list.fold(rects, 0, fn(acc, rect) { acc + rect.1 + rect.3 / 2 })
                / count
              let next =
                update_active_form(state, fn(_) {
                  align_form(
                    form,
                    list.zip(roots, rects),
                    kind,
                    min_x,
                    max_right,
                    min_y,
                    max_bottom,
                    avg_cx,
                    avg_cy,
                  )
                })
              commit(
                state,
                status(
                  next,
                  "Aligned " <> int.to_string(count) <> " components",
                ),
              )
            }
          }
        }
      }
    }
  }
}

// Fold the rects' field `index` (0=x 1=y 2=w 3=h) with the given extreme.
fn fold_rect(
  rects: List(#(Int, Int, Int, Int)),
  start: Int,
  index: Int,
) -> Int {
  list.fold(rects, start, fn(acc, rect) {
    let value = case index {
      0 -> rect.0
      1 -> rect.1
      2 -> rect.2
      _ -> rect.3
    }
    case index == 0 || index == 1 {
      True -> int.min(acc, value)
      False -> int.max(acc, value)
    }
  })
}

fn align_form(
  form: Form,
  pairs: List(#(String, #(Int, Int, Int, Int))),
  kind: String,
  min_x: Int,
  max_right: Int,
  min_y: Int,
  max_bottom: Int,
  avg_cx: Int,
  avg_cy: Int,
) -> Form {
  list.fold(pairs, form, fn(acc, pair) {
    let #(id, rect) = pair
    let #(x, y, w, h) = rect
    let #(tx, ty) = case kind {
      "left" -> #(min_x, y)
      "right" -> #(max_right - w, y)
      "center" -> #(avg_cx - w / 2, y)
      "top" -> #(x, min_y)
      "bottom" -> #(x, max_bottom - h)
      "middle" -> #(x, avg_cy - h / 2)
      _ -> #(x, y)
    }
    let dx = tx - x
    let dy = ty - y
    case dx == 0 && dy == 0 {
      True -> acc
      False ->
        list.fold(campy_form.subtree_ids(acc, id), acc, fn(inner, sid) {
          campy_form.update_selected(inner, sid, fn(control) {
            campy_form.Control(
              ..control,
              x: int.clamp(control.x + dx, 0, campy_form.max_coordinate),
              y: int.clamp(control.y + dy, 0, campy_form.max_coordinate),
            )
          })
        })
    }
  })
}

// The inspector grid commits one property for the whole selection (or the
// module window when nothing is selected) as a single undo step.
pub fn apply_prop(state: State, key: String, value: String) -> State {
  case state.selected, active_form(state) {
    Some(_), Some(_) -> {
      let next =
        list.fold(state.selection, state, fn(acc, id) {
          case active_form(acc) {
            Some(current) -> apply_control_prop(acc, current, id, key, value)
            None -> acc
          }
        })
      commit(state, next)
    }
    None, Some(form) ->
      commit(state, commit_form_field(state, form, key, value))
    _, _ -> status(state, "Open a module first")
  }
}

fn apply_control_prop(
  state: State,
  form: Form,
  id: String,
  key: String,
  value: String,
) -> State {
  case key {
    "name" ->
      case list.length(state.selection) == 1 {
        True -> commit_control_field(state, form, id, "name", value)
        False -> status(state, "Name applies to a single component")
      }
    // `text` is also a universal CCL property; the inspector's text row must
    // route to the control's text field (Z1.1 note), never to the prop store.
    "text" -> commit_control_field(state, form, id, "text", value)
    "color" ->
      update_active_form(state, fn(_) {
        campy_form.set_color_for(form, id, value)
      })
    "enabled" | "visible" -> {
      let on = value == "true"
      change_control(state, form, id, fn(control) {
        case key {
          "enabled" -> campy_form.Control(..control, enabled: on)
          _ -> campy_form.Control(..control, visible: on)
        }
      })
    }
    "align" ->
      update_active_form(state, fn(_) {
        campy_form.set_align(form, id, align_from_name(value))
      })
    "layout" ->
      case campy_form.find_control(form, id) {
        Some(control) ->
          case campy_form.accepts_children(control.kind) {
            True ->
              update_active_form(state, fn(_) {
                campy_form.set_layout_for(form, id, layout_from_name(value))
              })
            False -> state
          }
        None -> state
      }
    _ ->
      // Schema properties (placeholder-text, read-only, checked, minimum,
      // maximum, current-index) live on the control itself.
      case campy_form.find_control(form, id) {
        Some(control) ->
          case
            list.any(
              campy_ccl.properties(campy_form.kind_key(control.kind)),
              fn(property: campy_ccl.Property) { property.key == key },
            )
          {
            True ->
              update_active_form(state, fn(_) {
                campy_form.set_control_prop(form, id, key, value)
              })
            False -> commit_control_field(state, form, id, key, value)
          }
        None -> state
      }
  }
}

pub fn copy_selected(state: State) -> State {
  case active_form(state) {
    None -> status(state, "Select a component to copy")
    Some(form) -> {
      let roots = selection_roots(state, form)
      case roots {
        [] -> status(state, "Select a component to copy")
        _ -> {
          let ids =
            roots
            |> list.flat_map(fn(root) { campy_form.subtree_ids(form, root) })
            |> list.unique
          let ordered_ids =
            roots
            |> list.flat_map(fn(root) {
              [root, ..campy_form.descendant_ids(form, root)]
            })
            |> list.unique
          let controls =
            list.filter_map(ordered_ids, fn(id) {
              case campy_form.find_control(form, id) {
                Some(control) -> Ok(control)
                None -> Error(Nil)
              }
            })
          let parents =
            list.filter(form.parents, fn(entry) { list.contains(ids, entry.0) })
          let aligns =
            list.filter(form.aligns, fn(entry) { list.contains(ids, entry.0) })
          let layouts =
            list.filter(form.layouts, fn(entry) { list.contains(ids, entry.0) })
          let borders =
            list.filter(form.borders, fn(entry) { list.contains(ids, entry.0) })
          let transparencies =
            list.filter(form.transparencies, fn(entry) {
              list.contains(ids, entry.0)
            })
          let colors =
            list.filter(form.colors, fn(entry) { list.contains(ids, entry.0) })
          State(
            ..state,
            clipboard: Some(Clipboard(
              controls,
              parents,
              aligns,
              layouts,
              borders,
              transparencies,
              colors,
            )),
            status: case list.length(state.selection) {
              1 -> "Component copied"
              count -> int.to_string(count) <> " components copied"
            },
          )
        }
      }
    }
  }
}

pub fn cut_selected(state: State) -> State {
  case state.selection {
    [] -> status(state, "Select a component to cut")
    _ -> {
      let count = list.length(state.selection)
      let copied = copy_selected(state)
      let removed = delete_selected(copied)
      State(..removed, status: case count {
        1 -> "Component cut"
        _ -> int.to_string(count) <> " components cut"
      })
    }
  }
}

pub fn paste(state: State) -> State {
  case state.clipboard, active_form(state) {
    Some(Clipboard(
      controls,
      parents,
      aligns,
      layouts,
      borders,
      transparencies,
      colors,
    )),
      Some(form)
    -> {
      let #(form, pasted) =
        campy_form.paste_controls(
          form,
          controls,
          parents,
          aligns,
          layouts,
          borders,
          transparencies,
          colors,
          adoption_target(state),
        )
      let next = update_active_form(state, fn(_) { form })
      commit(state, case pasted {
        Some(control) ->
          State(
            ..next,
            selected: Some(control.id),
            selection: [control.id],
            tab: Properties,
            status: "Pasted " <> control.name,
          )
        None -> next
      })
    }
    _, _ -> status(state, "Clipboard is empty")
  }
}

pub fn set_font(state: State, font: String) -> State {
  State(..state, font: font)
}

pub fn set_font_size(state: State, size: Int) -> State {
  State(..state, font_size: int.max(8, int.min(48, size)))
}

pub fn set_scheme(state: State, scheme: Scheme) -> State {
  State(..state, scheme: scheme)
}

/// The window's size, as the renderer reported it. Ignored when unchanged so a
/// steady window costs nothing.
pub fn set_window_size(state: State, width: Int, height: Int) -> State {
  let size = #(int.max(width, 640), int.max(height, 480))
  case state.window_size == size {
    True -> state
    False -> State(..state, window_size: size)
  }
}

/// A hover hint (the renderer's `hover` event): the hint takes the status line
/// while the pointer is on the control, and leaving puts the old message back.
/// Ignored when the settings dialog's "Show UI hints" is off.
pub fn hover(state: State, hint: String) -> State {
  case hint, state.hints {
    "", _ ->
      case state.hover_status {
        Some(previous) -> State(..state, status: previous, hover_status: None)
        None -> state
      }
    text, True ->
      State(
        ..state,
        status: text,
        hover_status: Some(option.unwrap(state.hover_status, state.status)),
      )
    _, False -> state
  }
}

pub fn set_settings_open(state: State, open: Bool) -> State {
  State(..state, settings_open: open)
}

pub fn open_context_menu(state: State, payload: String) -> State {
  // The payload carries the click position in canvas coordinates:
  // "id;px;py" (right-click on a control or the canvas background).
  let #(id, x, y) = case string.split(payload, ";") {
    [id, x_text, y_text, ..] -> #(id, int_or(x_text, 8), int_or(y_text, 8))
    _ -> #(payload, 8, 8)
  }
  // Right-clicking a control that is already in the selection keeps the whole
  // selection (so multi-selection commands like Align stay available);
  // right-clicking elsewhere selects that control, or clears on the canvas.
  let picked = case id {
    "" -> select(state, "")
    _ ->
      case list.contains(state.selection, id) {
        True -> state
        False -> select(state, id)
      }
  }
  State(
    ..picked,
    context_open: True,
    context_x: x,
    context_y: y,
    context_align: False,
  )
}

pub fn close_context_menu(state: State) -> State {
  State(..state, context_open: False, context_align: False)
}

// The Align submenu of the canvas context menu toggles next to the menu.
pub fn toggle_context_align(state: State) -> State {
  State(..state, context_align: !state.context_align)
}

pub fn set_project_dialog_open(state: State, open: Bool) -> State {
  State(..state, project_dialog_open: open)
}

fn commit_project(
  state: State,
  updated: project.Project,
  status: String,
) -> State {
  let ws = workspace.update_active(state.workspace, updated)
  commit(state, State(..state, project: updated, workspace: ws, status: status))
}

pub fn set_project_icon(state: State, icon: String) -> State {
  commit_project(
    state,
    project.Project(..state.project, icon: icon),
    case icon {
      "" -> "Project icon cleared"
      _ -> "Project icon set"
    },
  )
}

pub fn commit_project_field(
  state: State,
  field: String,
  value: String,
) -> State {
  case field {
    "title" ->
      commit_project(
        state,
        project.Project(..state.project, title: value),
        "Project title updated",
      )
    "default-module" -> {
      // The chooser offers module names; the model stores the id.
      let id = case value {
        "" -> ""
        _ ->
          case
            list.find(state.project.modules, fn(module) { module.name == value })
          {
            Ok(module) -> module.id
            Error(_) -> value
          }
      }
      let next = project.set_default_module(state.project, id)
      let note = case project.default_module(next) {
        Some(module) -> "App: " <> module.name
        None -> "Project has no app (not runnable)"
      }
      commit_project(state, next, note)
    }
    _ -> state
  }
}

pub fn set_agent_open(state: State, open: Bool) -> State {
  State(..state, agent_open: open)
}

pub fn set_mcp_port(state: State, port: Int) -> State {
  State(..state, mcp_port: port)
}

pub fn set_mcp(state: State, enabled: Bool, status: String) -> State {
  State(..state, mcp_enabled: enabled, mcp_status: status)
}

pub fn window_position(state: State) -> #(Int, Int) {
  case active_module(state) {
    None -> #(32, 40)
    Some(module) ->
      case
        list.find(state.window_positions, fn(entry) { entry.0 == module.id })
      {
        Ok(entry) -> entry.1
        Error(_) -> #(32, 40)
      }
  }
}

pub fn move_window(state: State, dx: Int, dy: Int) -> State {
  case active_module(state) {
    None -> state
    Some(module) -> {
      let #(x, y) = window_position(state)
      let position = #(
        int.max(0, int.min(2000, x + dx)),
        int.max(0, int.min(2000, y + dy)),
      )
      State(..state, window_positions: [
        #(module.id, position),
        ..list.filter(state.window_positions, fn(entry) { entry.0 != module.id })
      ])
    }
  }
}

fn resize_form_raw(state: State, dw: Int, dh: Int) -> State {
  case active_form(state) {
    None -> state
    Some(form) ->
      update_active_form(state, fn(_) {
        campy_form.Form(
          ..form,
          width: int.clamp(form.width + dw, 240, campy_form.max_form_size),
          height: int.clamp(form.height + dh, 160, campy_form.max_form_size),
        )
      })
  }
}

pub fn resize_window_w(state: State, dw: Int) -> State {
  gesture_change(state, resize_form_raw(state, dw, 0))
}

pub fn resize_window_h(state: State, dh: Int) -> State {
  gesture_change(state, resize_form_raw(state, 0, dh))
}

pub fn scheme_from_name(name: String) -> Scheme {
  case name {
    "Light" -> Light
    "Solarized" -> Solarized
    _ -> Dark
  }
}

// Open the event handler in the code pane, creating a stub when required.
// `event_key` is the CCL event (clicked, edited, toggled, ...); the handler
// name follows the Delphi convention <name>_<event>.
pub fn open_event(state: State, event_key: String) -> State {
  case selected_control(state) {
    None -> status(state, "Select a control first")
    Some(control) ->
      case active_module(state) {
        None -> status(state, "Open a module first")
        Some(module) -> {
          let handler = campy_form.handler_name(control, event_key)
          // The handler's stub is ensured, but the editor always edits
          // the module's whole source (ready for LSP and search).
          let #(source, _) =
            campy_form.ensure_handler(module_source(module), handler)
          let module = set_module_source(module, source)
          commit(
            state,
            State(
              ..state,
              project: project.update_module(state.project, module),
              view: CodeView,
              active_handler: Some(handler),
              highlight: None,
              editing: None,
              editor: Edit,
              status: "Editing " <> handler,
            ),
          )
        }
      }
  }
}

/// How close two clicks must be in time to make a double-click.
pub const double_click_ms = 400

/// Records a click on the current selection and says whether it completes a
/// pair: two clicks on the same component within `double_click_ms`.
pub fn click_pair(state: State, at: Int) -> #(State, Bool) {
  case state.selected {
    None -> #(State(..state, last_click: None), False)
    Some(id) ->
      case state.last_click {
        Some(#(last_id, last_at))
          if last_id == id && at >= last_at && at - last_at <= double_click_ms
        -> #(State(..state, last_click: None), True)
        _ -> #(State(..state, last_click: Some(#(id, at))), False)
      }
  }
}

/// The event a double-click opens: what this kind is for. A button is
/// clicked, a check box toggled, a field edited, a list or menu selected.
pub fn default_event(kind: Kind) -> Option(String) {
  let keys =
    campy_ccl.events(campy_form.kind_key(kind))
    |> list.map(fn(event) { event.key })
  let preferred = [
    "clicked", "toggled", "edited", "selected", "changed", "accepted",
  ]
  case list.find(preferred, fn(key) { list.contains(keys, key) }) {
    Ok(key) -> Some(key)
    Error(_) ->
      case list.first(keys) {
        Ok(key) -> Some(key)
        Error(_) -> None
      }
  }
}

/// Double-clicking a component opens its default handler in the code pane.
/// The inspector keeps whichever tab it was showing.
pub fn open_default_event(state: State) -> State {
  case selected_control(state) {
    None -> state
    Some(control) ->
      case default_event(control.kind) {
        Some(key) -> open_event(state, key)
        None -> state
      }
  }
}

pub fn enter_edit(state: State) -> State {
  state
}

pub fn leave_edit(state: State) -> State {
  state
}

// ---------------------------------------------------------------------------
// Code editor: auto-committed buffer, caret, completions, diagnostics
// ---------------------------------------------------------------------------

@external(erlang, "campy_lsp_ffi", "cwd")
fn beem_cwd() -> String

fn int_or(text: String, fallback: Int) -> Int {
  case int.parse(text) {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

// The editor's live buffer IS the module source: every keystroke updates it
// directly (no undo entry, no Apply), so F7/F5 always compile and run
// whatever is on screen.
pub fn code_edit(state: State, payload: String) -> State {
  case string.split_once(payload, ";") {
    Error(_) -> state
    Ok(#(line_text, rest)) ->
      case string.split_once(rest, ";") {
        Error(_) -> state
        Ok(#(col_text, text)) -> {
          let caret = #(int_or(line_text, 0), int_or(col_text, 0))
          let state = commit_source(state, text)
          let state =
            State(
              ..state,
              caret: caret,
              lsp_uri: lsp_document_uri(state),
              code_version: state.code_version + 1,
            )
          // An open popup stays in register with the new text; a bare
          // identifier never opens one (it would cover the code being typed).
          case run_at_caret(state) {
            "" -> completion_close(state)
            _ ->
              State(
                ..state,
                completions: filtered_completions(
                  state.completions,
                  segment_of_run(run_at_caret(state)),
                ),
              )
          }
        }
      }
  }
}

// A whole-buffer edit from a protocol-v2 `editor:<id>:changed` event (the
// editor owns the caret, so none crosses with the text yet).
pub fn code_changed(state: State, text: String) -> State {
  State(
    ..commit_source(state, text),
    lsp_uri: lsp_document_uri(state),
    code_version: state.code_version + 1,
  )
}

// Commit a buffer into the active module: embedded modules keep the text in
// the term, external modules write their file (the codec stores only a path).
fn commit_source(state: State, text: String) -> State {
  case active_module(state) {
    Some(module) ->
      State(
        ..state,
        project: project.update_module(
          state.project,
          set_module_source(module, text),
        ),
      )
    None -> state
  }
}

// The virtual document the language server edits: one dedicated scratch
// module hosts the live buffer (its content is replaced via
// didOpen/didChange, so the server always analyzes the current text).
// Windows returns backslash paths without a drive slash, so normalize to
// file:///C:/... form.
pub fn lsp_document_uri(_state: State) -> String {
  let path = string.replace(beem_cwd(), "\\", "/")
  "file:///" <> path <> "/src/campy_handlers.gleam"
}

pub fn completion_close(state: State) -> State {
  State(..state, completions: [], completion_index: 0)
}

// Ctrl+Space: the next server response opens the popup regardless of the
// typed word.
pub fn completion_requested(state: State) -> State {
  State(..state, completions_requested: True)
}

pub fn completion_move(state: State, delta: Int) -> State {
  let count = list.length(state.completions)
  case count {
    0 -> state
    _ ->
      State(
        ..state,
        completion_index: int.clamp(
          state.completion_index + delta,
          0,
          count - 1,
        ),
      )
  }
}

fn buffer_text(state: State) -> String {
  case active_module(state) {
    Some(module) -> module_source(module)
    None -> ""
  }
}

// The identifier run before the caret on its line (dots included, so
// qualified names like io.pr stay in one run).
fn run_at_caret(state: State) -> String {
  identifier_run(buffer_text(state), state.caret)
}

fn identifier_run(text: String, caret: #(Int, Int)) -> String {
  let #(line, col) = caret
  let line_text =
    text
    |> string.split("\n")
    |> list.drop(line)
    |> list.first
    |> result.unwrap("")
  line_text
  |> string.slice(0, int.clamp(col, 0, string.length(line_text)))
  |> string.to_graphemes
  |> list.reverse
  |> list.take_while(is_identifier_char)
  |> list.reverse
  |> string.concat
}

// The part of the run a completion replaces: after the last dot for
// qualified names, the whole run otherwise.
fn segment_of_run(run: String) -> String {
  run
  |> string.split(".")
  |> list.last
  |> result.unwrap("")
}

fn is_identifier_char(grapheme: String) -> Bool {
  case grapheme {
    "_" | "." -> True
    _ ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        grapheme,
      )
  }
}

// Accept the selected completion: replace the segment before the caret with
// the item's insert text (auto-committed) and move the caret past it. The
// loop pushes the spliced buffer back to the shell and the tokenizer.
pub fn completion_accept(state: State) -> State {
  case list.drop(state.completions, state.completion_index) {
    [selected, ..] -> {
      let #(line, col) = state.caret
      let segment = segment_of_run(run_at_caret(state))
      let new_text =
        splice_insert(buffer_text(state), state.caret, segment, selected.insert)
      let state = commit_source(state, new_text)
      State(
        ..state,
        caret: #(
          line,
          col - string.length(segment) + string.length(selected.insert),
        ),
        completions: [],
        completion_index: 0,
      )
    }
    [] -> completion_close(state)
  }
}

// A clicked row carries its index.
pub fn completion_click(state: State, payload: String) -> State {
  completion_accept(State(..state, completion_index: int_or(payload, 0)))
}

fn splice_insert(
  draft: String,
  caret: #(Int, Int),
  prefix: String,
  insert: String,
) -> String {
  let #(line, col) = caret
  let lines = string.split(draft, "\n")
  case list.drop(lines, line) {
    [current, ..rest] -> {
      let before =
        string.slice(
          current,
          0,
          int.clamp(col - string.length(prefix), 0, string.length(current)),
        )
      let tail =
        string.drop_start(current, int.clamp(col, 0, string.length(current)))
      let replaced = before <> insert <> tail
      list.append(list.take(lines, line), [replaced, ..rest])
      |> string.join("\n")
    }
    [] -> draft
  }
}

// Campy's own completion context: the application, modules, forms,
// components and their properties.
pub fn campy_completions(state: State) -> List(Completion) {
  let modules =
    state.project.modules
    |> list.map(fn(module) { Completion(module.name, "module", module.name) })
  let forms =
    state.project.modules
    |> list.map(fn(module) {
      Completion(module.form.title, "form", module.form.title)
    })
  let components = case active_form(state) {
    Some(form) ->
      campy_form.render_controls(form)
      |> list.map(fn(control) {
        Completion(control.name, "component", control.name)
      })
    None -> []
  }
  let properties =
    [
      "text",
      "x",
      "y",
      "w",
      "h",
      "enabled",
      "visible",
      "transparency",
      "border",
      "align",
      "layout",
    ]
    |> list.map(fn(name) { Completion(name, "property", name) })
  list.flatten([
    [Completion("application", "Campy application", "application")],
    modules,
    forms,
    components,
    properties,
  ])
}

// What the popup shows for the run being typed: after a dot it is the
// server's member list; a forced request (Ctrl+Space) or an already-open
// popup merges the Campy context items with the server's results; a bare
// identifier with no popup shows nothing (auto-popup would cover the code).
fn completions_for_run(
  state: State,
  run: String,
  server: List(Completion),
) -> List(Completion) {
  case run {
    "" -> []
    _ ->
      case string.contains(run, ".") {
        True -> filtered_completions(server, segment_of_run(run))
        False ->
          case state.completions_requested || state.completions != [] {
            True ->
              list.append(campy_completions(state), server)
              |> dedupe_completions([])
              |> filtered_completions(segment_of_run(run))
            False -> []
          }
      }
  }
}

// Server completions arrive as `label\tdetail\tinsert\tkind` rows.
pub fn completions_arrived(state: State, payload: String) -> State {
  let server =
    payload
    |> string.split("\n")
    |> list.filter_map(fn(row) {
      case string.split(row, "\t") {
        [label, detail, insert, ..] -> Ok(Completion(label, detail, insert))
        _ -> Error(Nil)
      }
    })
  let run = run_at_caret(state)
  State(
    ..state,
    completions: completions_for_run(state, run, server),
    completion_index: 0,
    completions_requested: False,
  )
}

fn dedupe_completions(
  seen: List(Completion),
  items: List(Completion),
) -> List(Completion) {
  case items {
    [] -> list.reverse(seen)
    [item, ..rest] ->
      case list.any(seen, fn(existing) { existing.label == item.label }) {
        True -> dedupe_completions(seen, rest)
        False -> dedupe_completions([item, ..seen], rest)
      }
  }
}

fn filtered_completions(
  items: List(Completion),
  prefix: String,
) -> List(Completion) {
  case prefix {
    // An empty segment (just typed a dot) shows the whole member list.
    "" -> items
    _ ->
      list.filter(items, fn(item) {
        string.starts_with(
          string.lowercase(item.label),
          string.lowercase(prefix),
        )
      })
  }
}

// Diagnostics arrive as `line\tseverity\tmessage` rows.
pub fn diagnostics_arrived(state: State, payload: String) -> State {
  let rows =
    payload
    |> string.split("\n")
    |> list.filter_map(fn(row) {
      case string.split(row, "\t") {
        [line_text, severity_text, message] ->
          Ok(#(int_or(line_text, 0), int_or(severity_text, 1), message))
        _ -> Error(Nil)
      }
    })
  State(..state, diagnostics: rows)
}

// ---------------------------------------------------------------------------
// In-app file browser (generic dialog for every file operation)
// ---------------------------------------------------------------------------

pub type FileFilter {
  All
  Images
}

@external(erlang, "campy_fs_ffi", "list_dir")
fn fs_list_dir(path: String) -> Result(List(#(String, Bool)), Nil)

@external(erlang, "campy_fs_ffi", "read_file")
fn fs_read_file(path: String) -> Result(String, String)

@external(erlang, "campy_fs_ffi", "write_file")
fn fs_write_file(path: String, text: String) -> Result(Nil, String)

// ---------------------------------------------------------------------------
// Module source (codec v12: embedded text or an external file)
// ---------------------------------------------------------------------------

/// A module's handler source. Embedded modules carry it in the term; external
/// modules store only a path, so the IDE reads the file (the codec never does).
pub fn module_source(module: Module) -> String {
  case module.source_origin {
    project.Embedded(text) -> text
    project.External(path) ->
      case fs_read_file(path) {
        Ok(text) -> text
        Error(_) -> ""
      }
  }
}

/// Commit edited source back to the module: embedded keeps the text, external
/// writes the file and keeps the path.
pub fn set_module_source(module: Module, text: String) -> Module {
  case module.source_origin {
    project.Embedded(_) ->
      project.Module(..module, source_origin: project.Embedded(text))
    project.External(_) -> {
      let _ = fs_write_file(external_path(module), text)
      module
    }
  }
}

fn external_path(module: Module) -> String {
  case module.source_origin {
    project.Embedded(_) -> ""
    project.External(path) -> path
  }
}

@external(erlang, "campy_fs_ffi", "home")
fn fs_home() -> String

@external(erlang, "campy_fs_ffi", "make_dir")
fn fs_make_dir(path: String) -> Result(Nil, String)

fn sort_entries(entries: List(#(String, Bool))) -> List(BrowserEntry) {
  let dirs =
    entries
    |> list.filter(fn(entry) { { entry }.1 })
    |> list.map(fn(entry) { BrowserEntry({ entry }.0, True) })
    |> list.sort(fn(a, b) {
      string.compare(string.lowercase(a.name), string.lowercase(b.name))
    })
  let files =
    entries
    |> list.filter(fn(entry) { !{ entry }.1 })
    |> list.map(fn(entry) { BrowserEntry({ entry }.0, False) })
    |> list.sort(fn(a, b) {
      string.compare(string.lowercase(a.name), string.lowercase(b.name))
    })
  list.append(dirs, files)
}

/// Files the dialog offers, by what it is for: a project picker shows project
/// files and a picture picker shows images, so a click cannot open something
/// the codec will refuse.
fn entry_matches(mode: Popup, name: String) -> Bool {
  let lower = string.lowercase(name)
  case mode {
    OpenFile | SaveAs -> string.ends_with(lower, ".campy")
    PickPicture | PickProjectIcon ->
      list.any(
        [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"],
        fn(extension) { string.ends_with(lower, extension) },
      )
    _ -> True
  }
}

fn read_entries(mode: Popup, dir: String) -> List(BrowserEntry) {
  case fs_list_dir(dir) {
    Ok(entries) ->
      sort_entries(
        list.filter(entries, fn(entry) {
          { entry }.1 || entry_matches(mode, { entry }.0)
        }),
      )
    Error(_) -> []
  }
}

// Open the browser for one of the Popup modes. Empty/relative start
// directories resolve against the working directory.
pub fn browser_open(
  state: State,
  mode: Popup,
  dir: String,
  name: String,
) -> State {
  let dir = case dir {
    "" -> fs_home()
    path ->
      case string.starts_with(path, "/") {
        True -> path
        False -> beem_cwd()
      }
  }
  State(
    ..state,
    popup: mode,
    browser: Some(Browser(mode, dir, name, read_entries(mode, dir))),
  )
}

pub fn browser_navigate(state: State, dir: String) -> State {
  case state.browser {
    Some(browser) ->
      State(
        ..state,
        browser: Some(
          Browser(..browser, dir: dir, entries: read_entries(browser.mode, dir)),
        ),
      )
    None -> state
  }
}

pub fn browser_up(state: State) -> State {
  case state.browser {
    Some(browser) -> {
      let parts =
        browser.dir
        |> string.split("/")
        |> list.filter(fn(part) { part != "" })
      let parent = case list.take(parts, list.length(parts) - 1) {
        [] -> "/"
        kept -> "/" <> string.join(kept, "/")
      }
      browser_navigate(state, parent)
    }
    None -> state
  }
}

pub fn browser_home(state: State) -> State {
  browser_navigate(state, fs_home())
}

// Create a directory named after the current Name field, then navigate in.
pub fn browser_new_dir(state: State) -> State {
  case state.browser {
    Some(browser) ->
      case string.trim(browser.name) {
        "" -> status(state, "Type a name for the new folder first")
        name -> {
          let path = join_path(browser.dir, name)
          case fs_make_dir(path) {
            Ok(_) ->
              browser_navigate(state, path)
              |> status("Created folder " <> name)
            Error(error) -> status(state, "Cannot create folder: " <> error)
          }
        }
      }
    None -> state
  }
}

// A clicked row: directories navigate, files become the selected name.
pub fn browser_pick(state: State, payload: String) -> State {
  case string.split_once(payload, ";") {
    Ok(#(name, is_dir_text)) ->
      case state.browser, is_dir_text == "1" {
        Some(browser), True ->
          browser_navigate(state, join_path(browser.dir, name))
        Some(browser), False ->
          State(..state, browser: Some(Browser(..browser, name: name)))
        None, _ -> state
      }
    Error(_) -> state
  }
}

// Accept: the selected (or typed) name resolves against the current
// directory; the caller dispatches it through the popup accept path.
pub fn browser_close(state: State) -> State {
  State(..state, browser: None)
}

// The Name field of the in-app browser (a folder to create, or a path to open).
pub fn browser_set_name(state: State, name: String) -> State {
  case state.browser {
    Some(browser) ->
      State(..state, browser: Some(Browser(..browser, name: name)))
    None -> state
  }
}

pub fn browser_path(state: State) -> String {
  case state.browser {
    Some(browser) -> join_path(browser.dir, browser.name)
    None -> ""
  }
}

fn join_path(dir: String, name: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> name
    False -> dir <> "/" <> name
  }
}

pub fn browser_cancel(state: State) -> State {
  State(..state, browser: None, popup: NoPopup)
}

// ---------------------------------------------------------------------------
// Navigator context menu (projects / modules)
// ---------------------------------------------------------------------------

// Payload: "kind;id" where kind is "project" or "module".
pub fn nav_context_menu(state: State, payload: String) -> State {
  case string.split_once(payload, ";") {
    Ok(#(kind, id)) ->
      State(..state, nav_context_open: True, nav_kind: kind, nav_id: id)
    Error(_) -> state
  }
}

pub fn nav_context_close(state: State) -> State {
  State(..state, nav_context_open: False)
}

// Delete the menu's target: projects leave the workspace (the file stays on
// disk); modules are removed from the project (undo restores them).
pub fn nav_delete(state: State) -> State {
  let state = State(..state, nav_context_open: False)
  case state.nav_kind, state.nav_id {
    "project", path ->
      case workspace.find(state.workspace, path) {
        None -> state
        Some(target) ->
          case workspace.count(state.workspace) <= 1 {
            True -> status(state, "A workspace needs at least one project")
            False -> {
              let removed = workspace.remove(state.workspace, path)
              case workspace.active_project(removed) {
                Some(next) ->
                  with_project(state, removed, next)
                  |> status("Removed " <> target.title <> " from the workspace")
                None -> state
              }
            }
          }
      }
    "module", id -> delete_module(state, id)
    _, _ -> state
  }
}

// ---------------------------------------------------------------------------
// Console error navigation
// ---------------------------------------------------------------------------

// Clicking a console row that looks like "line N: msg" jumps to the code
// view; the shell scrolls the editor to that line.
pub fn console_goto(state: State, line: Int) -> State {
  State(
    ..set_view(state, CodeView),
    code_jump: Some(line),
    code_jump_nonce: state.code_jump_nonce + 1,
  )
}

pub fn take_code_jump(state: State) -> #(State, Int) {
  case state.code_jump {
    Some(line) -> #(State(..state, code_jump: None), line)
    None -> #(state, -1)
  }
}

pub fn set_project(_state: State, project: Project) -> State {
  let next = initial(project)
  State(..next, status: "Project loaded")
}

// Keeps the open tabs and selection when the project is only persisted.
pub fn set_saved(state: State, saved: Project) -> State {
  let ws = case saved.path == state.project.path {
    True -> workspace.update_active(state.workspace, saved)
    False -> workspace.replace_path(state.workspace, state.project.path, saved)
  }
  State(..state, project: saved, workspace: ws)
}

pub fn set_status(state: State, message: String) -> State {
  status(state, message)
}

pub fn set_popup(state: State, popup: Popup) -> State {
  State(..state, popup: popup)
}

/// The app window running `module_id`, if it has one.
pub fn preview_for(state: State, module_id: String) -> Option(Preview) {
  case list.find(state.previews, fn(preview) { preview.module == module_id }) {
    Ok(preview) -> Some(preview)
    Error(_) -> None
  }
}

pub fn running_module(state: State, module_id: String) -> Bool {
  list.any(state.previews, fn(preview) { preview.module == module_id })
}

pub fn any_running(state: State) -> Bool {
  !list.is_empty(state.previews)
}

/// Starts (or replaces) the app window of one module.
pub fn put_preview(state: State, preview: Preview) -> State {
  State(..state, previews: [
    preview,
    ..list.filter(state.previews, fn(other) { other.module != preview.module })
  ])
}

pub fn drop_preview(state: State, module_id: String) -> State {
  State(
    ..state,
    previews: list.filter(state.previews, fn(preview) {
      preview.module != module_id
    }),
  )
}

/// Forgets the preview whose session closed (the user closed its window).
pub fn drop_preview_session(state: State, session: Int) -> State {
  State(
    ..state,
    previews: list.filter(state.previews, fn(preview) { preview.id != session }),
  )
}

// Cycle the open tabs (the renderer's list rows cannot be clicked yet, so the
// loop offers a keyboard path; see the Z2.3 report).
pub fn cycle_tab(state: State, step: Int) -> State {
  case state.opened {
    [] -> state
    ids -> {
      let count = list.length(ids)
      let current = index_of_id(ids, state.active, 0)
      let target = modulo(current + step, count)
      case list.drop(ids, target) {
        [id, ..] -> activate_module(state, id)
        [] -> state
      }
    }
  }
}

fn index_of_id(ids: List(String), id: String, index: Int) -> Int {
  case ids {
    [] -> 0
    [first, ..rest] ->
      case first == id {
        True -> index
        False -> index_of_id(rest, id, index + 1)
      }
  }
}

fn modulo(value: Int, modulus: Int) -> Int {
  case modulus <= 0 {
    True -> 0
    False -> {
      let remainder = value % modulus
      case remainder < 0 {
        True -> remainder + modulus
        False -> remainder
      }
    }
  }
}

pub fn selection_roots(state: State, form: Form) -> List(String) {
  list.filter(state.selection, fn(id) {
    !list.any(state.selection, fn(other) {
      other != id && list.contains(campy_form.descendant_ids(form, other), id)
    })
  })
}

pub fn selection_subtree_ids(state: State, form: Form) -> List(String) {
  selection_roots(state, form)
  |> list.flat_map(fn(root) { campy_form.subtree_ids(form, root) })
  |> list.unique
}

pub fn log_console(state: State, line: String) -> State {
  let line = case string.length(line) > 500 {
    True -> string.slice(line, 0, 500)
    False -> line
  }
  let lines = list.append(state.console, [line])
  let lines = case list.length(lines) > 400 {
    True -> list.drop(lines, list.length(lines) - 400)
    False -> lines
  }
  State(..state, console: lines)
}

pub fn clear_console(state: State) -> State {
  State(..state, console: [])
}

pub fn console_input(state: State, text: String) -> State {
  let next = log_console(state, "> " <> text)
  let next = case state.previews {
    [_, ..] -> log_console(next, "stdin → running app")
    [] -> log_console(next, "stdin: app is not running")
  }
  State(..next, status: "Console input sent")
}

pub fn console_text(state: State) -> String {
  string.join(state.console, "\n")
}

pub fn set_hints(state: State, hints: Bool) -> State {
  State(..state, hints: hints)
}

pub fn arm_component(state: State, key: String) -> State {
  case campy_form.kind_from_key(key) {
    None -> state
    Some(kind) ->
      State(
        ..state,
        pending_kind: Some(kind),
        drop_active: False,
        drop_candidate: "",
        status: "Drag on the form to place " <> campy_form.kind_label(kind),
      )
  }
}

pub fn cancel_pending(state: State) -> State {
  State(..state, pending_kind: None, status: "Placement cancelled")
}

pub fn set_rect_x(state: State, value: Int) -> State {
  let #(_, y, w, h) = state.rect
  State(..state, rect: #(value, y, w, h))
}

pub fn set_rect_y(state: State, value: Int) -> State {
  let #(x, _, w, h) = state.rect
  State(..state, rect: #(x, value, w, h))
}

pub fn set_rect_w(state: State, value: Int) -> State {
  let #(x, y, _, h) = state.rect
  State(..state, rect: #(x, y, value, h))
}

pub fn set_rect_h(state: State, value: Int) -> State {
  let #(x, y, w, _) = state.rect
  State(..state, rect: #(x, y, w, value))
}

pub fn select_frame(state: State, additive: Bool) -> State {
  case active_form(state) {
    None -> state
    Some(form) -> {
      let picked = frame_ids(form, state.rect)
      // Shift/Ctrl extends the frame selection instead of replacing it.
      let selection = case additive {
        True -> list.unique(list.append(state.selection, picked))
        False -> picked
      }
      let primary = case selection {
        [first, ..] -> Some(first)
        [] -> None
      }
      State(
        ..state,
        selected: primary,
        selection: selection,
        selected_project: False,
        active_handler: None,
        highlight: None,
        editing: None,
        status: case list.length(selection) {
          0 -> "No components in frame"
          1 -> "1 component selected"
          count -> int.to_string(count) <> " components selected"
        },
      )
    }
  }
}

pub fn place_component(state: State) -> State {
  case state.pending_kind, active_form(state) {
    None, _ -> state
    _, None -> status(state, "Open a module first")
    Some(kind), Some(form) -> {
      let #(start_x, start_y, dw, dh) = state.rect
      let left = int.max(0, int.min(start_x, start_x + dw))
      let top = int.max(0, int.min(start_y, start_y + dh))
      let abs_w = case dw < 0 {
        True -> -dw
        False -> dw
      }
      let abs_h = case dh < 0 {
        True -> -dh
        False -> dh
      }
      let width = int.clamp(abs_w, 8, campy_form.max_coordinate)
      let height = int.clamp(abs_h, 8, campy_form.max_coordinate)
      let parent = campy_form.container_at(form, start_x, start_y)
      let #(form, control) =
        campy_form.add_control_rect(
          form,
          kind,
          parent,
          left,
          top,
          width,
          height,
        )
      let next = update_active_form(state, fn(_) { form })
      commit(
        state,
        State(
          ..next,
          selected: Some(control.id),
          selection: [control.id],
          selected_project: False,
          tab: Properties,
          pending_kind: None,
          drop_active: False,
          drop_candidate: "",
          status: "Added " <> campy_form.kind_label(kind),
        ),
      )
    }
  }
}

// Pressing a control arms the drop tracking and remembers which control is
// under the pointer; the selection itself is only committed on release.
pub fn begin_drag(state: State, id: String) -> State {
  State(
    ..state,
    drop_active: False,
    drop_candidate: "",
    drop_x: 0,
    drop_y: 0,
    drag_control: Some(id),
  )
}

pub fn set_drop_x(state: State, value: Int) -> State {
  State(..state, drop_x: value)
}

// The drag-over position is the cursor, so the drop target follows the pointer
// rather than the dragged control's centre.
pub fn update_drop(state: State, y: Int) -> State {
  let tracked = State(..state, drop_y: y)
  case dragging_control(tracked), active_form(tracked) {
    Some(control), Some(form) -> {
      let target = drop_target_at(form, control, tracked.drop_x, y)
      let changed = target != campy_form.parent_of(form, control.id)
      State(..tracked, drop_active: changed, drop_candidate: case changed {
        True -> target
        False -> ""
      })
    }
    _, _ -> tracked
  }
}

// The control pressed at the start of a pointer drag; falls back to the
// inspector selection for moves that happen without a pointer gesture.
fn dragging_control(state: State) -> Option(Control) {
  case state.drag_control, active_form(state) {
    Some(id), Some(form) -> campy_form.find_control(form, id)
    _, _ -> selected_control(state)
  }
}

// ---------------------------------------------------------------------------
// Canvas pointer gestures (`pointer:<canvas>:down/move/up`, form-local px)
// ---------------------------------------------------------------------------
//
// The protocol-v2 surface forwards raw pointer phases instead of per-control
// touch areas, so the BEAM hit-tests from the form model. The contract is the
// old designer's hybrid one: a press selects on release, a drag past the
// threshold moves an already-selected control and draws a marquee from
// anything else, the title bar moves the module window, the bottom-right grip
// resizes it, and the primary selection's edges resize the control. Previews
// are ordinary model edits, so every move already produces the `SetGeometry`
// ops the loaded document needs.

pub const drag_threshold = 2

/// The hit radius of a selection grip, and the size of the square drawn for
/// it (see `shell.grip_size`, which the shell draws from).
pub const resize_grip = shell.grip_size

pub const window_grip = 14

/// The topmost designed control whose rendered bounds contain the point
/// (render order is container-then-children, so a later hit wins).
pub fn control_at(form: Form, x: Int, y: Int) -> Option(Control) {
  list.fold(campy_form.render_controls(form), None, fn(best, control) {
    let #(bx, by, bw, bh) = campy_form.bounds(form, control)
    case x >= bx && x <= bx + bw && y >= by && y <= by + bh {
      True -> Some(control)
      False -> best
    }
  })
}

pub fn pointer_down(state: State, x: Int, y: Int) -> State {
  let state =
    State(
      ..state,
      last_pointer: #(x, y),
      context_open: False,
      context_align: False,
      nav_context_open: False,
      drop_active: False,
      drop_candidate: "",
      drag_control: None,
    )
  case state.pending_kind {
    Some(_) -> State(..state, gesture: Placing(#(x, y)), rect: #(x, y, 0, 0))
    None ->
      case active_form(state) {
        None -> State(..state, gesture: Idle)
        // The module window's title bar: drag to move the window. The point
        // is kept in canvas coordinates: form coordinates move with the
        // window, and a delta taken from them chases its own output.
        Some(form) if y < 0 && y >= -28 && x >= 0 && x <= form.width ->
          State(..state, gesture: MovingWindow(canvas_point(state, x, y)))
        Some(form) ->
          case grip_at(state, form, x, y) {
            Some(#(mode, window)) ->
              State(
                ..begin_gesture(state),
                gesture: Resizing(mode, #(x, y), window),
              )
            None -> {
              // The selection's outline is its grab area, and it is checked
              // first: pressing the gap between two selected components (or
              // their container's background) drags the block. Pressing a
              // component that is not in the block selects that component.
              let grabbed = selection_grab(state, form, x, y)
              let target = case grabbed {
                "" ->
                  case control_at(form, x, y) {
                    Some(control) -> control.id
                    None -> ""
                  }
                id -> id
              }
              State(..state, gesture: Pressing(#(x, y), target))
            }
          }
      }
  }
}

// Which resize grip (if any) the press landed on: the primary selection's edge
// while it is selected, or the module window's bottom-right corner when
// nothing is selected. `#(mode, is_window)`.
fn grip_at(
  state: State,
  form: Form,
  x: Int,
  y: Int,
) -> Option(#(String, Bool)) {
  case state.selected, state.selection {
    Some(_), [_, ..] ->
      case selected_control(state) {
        Some(control) ->
          case
            campy_form.layout_of(form, campy_form.parent_of(form, control.id))
          {
            campy_form.Free ->
              control_grip(campy_form.bounds(form, control), x, y)
            _ -> None
          }
        None -> None
      }
    _, _ -> window_grip_hit(form, x, y)
  }
}

fn window_grip_hit(form: Form, x: Int, y: Int) -> Option(#(String, Bool)) {
  let #(left, top, width, height) = #(0, 0, form.width, form.height)
  let near_right = x >= left + width - window_grip && x <= left + width
  let near_bottom = y >= top + height - window_grip && y <= top + height
  case near_right && near_bottom {
    True -> Some(#("se", True))
    False -> None
  }
}

// Is the press within one of the eight 10×10 handles drawn around the
// primary selection (corners and edge midpoints, like the old designer)?
fn control_grip(
  bounds: #(Int, Int, Int, Int),
  x: Int,
  y: Int,
) -> Option(#(String, Bool)) {
  let #(left, top, width, height) = bounds
  let right = left + width
  let bottom = top + height
  let middle_x = left + width / 2
  let middle_y = top + height / 2
  let handles = [
    #("nw", left, top),
    #("n", middle_x, top),
    #("ne", right, top),
    #("w", left, middle_y),
    #("e", right, middle_y),
    #("sw", left, bottom),
    #("s", middle_x, bottom),
    #("se", right, bottom),
  ]
  case
    list.find(handles, fn(handle) {
      let #(_, cx, cy) = handle
      x >= cx - resize_grip / 2
      && x <= cx + resize_grip / 2
      && y >= cy - resize_grip / 2
      && y <= cy + resize_grip / 2
    })
  {
    Ok(#(mode, _, _)) -> Some(#(mode, False))
    Error(_) -> None
  }
}

pub fn pointer_move(state: State, x: Int, y: Int) -> State {
  case state.gesture {
    Idle -> State(..state, last_pointer: #(x, y))
    Pressing(press, target) ->
      case distance_over_threshold(press, #(x, y)) {
        False -> State(..state, last_pointer: #(x, y))
        True -> start_drag(state, press, target, x, y)
      }
    Moving(last) -> dragged(state, last, x, y)
    Marqueing(origin) -> marquee_to(state, origin, x, y)
    Placing(origin) -> marquee_to(state, origin, x, y)
    MovingWindow(last) -> {
      let #(canvas_x, canvas_y) = canvas_point(state, x, y)
      let next = move_window(state, canvas_x - last.0, canvas_y - last.1)
      State(..next, gesture: MovingWindow(#(canvas_x, canvas_y)))
    }
    Resizing(mode, last, window) -> resized(state, mode, last, x, y, window)
  }
}

fn distance_over_threshold(a: #(Int, Int), b: #(Int, Int)) -> Bool {
  let dx = a.0 - b.0
  let dy = a.1 - b.1
  dx * dx + dy * dy > drag_threshold * drag_threshold
}

fn start_drag(
  state: State,
  press: #(Int, Int),
  target: String,
  x: Int,
  y: Int,
) -> State {
  case target != "" && list.contains(state.selection, target) {
    True -> {
      let next =
        state
        |> begin_gesture
        |> begin_drag(target)
        |> set_drop_x(x)
        |> update_drop(y)
      dragged(next, press, x, y)
    }
    False -> marquee_to(State(..state, gesture: Marqueing(press)), press, x, y)
  }
}

fn dragged(state: State, last: #(Int, Int), x: Int, y: Int) -> State {
  let dx = x - last.0
  let dy = y - last.1
  let next = State(..state, last_pointer: #(x, y))
  case dx == 0 && dy == 0 {
    True -> next
    False -> {
      let next =
        next
        |> set_drop_x(x)
        |> update_drop(y)
        |> move_gesture_x(dx)
        |> move_gesture_y(dy)
      State(..next, gesture: Moving(#(x, y)))
    }
  }
}

fn marquee_to(state: State, origin: #(Int, Int), x: Int, y: Int) -> State {
  let rect = #(origin.0, origin.1, x - origin.0, y - origin.1)
  // The components the frame would select, live: the shell outlines them and
  // draws their handles while the button is still down.
  let preview = case active_form(state) {
    Some(form) -> frame_ids(form, rect)
    None -> []
  }
  State(..state, last_pointer: #(x, y), rect: rect, preview_selection: preview)
}

/// The components a marquee frame would pick: any of the eight points around
/// a control (corners, edge midpoints) inside the frame.
pub fn frame_ids(form: Form, rect: #(Int, Int, Int, Int)) -> List(String) {
  let #(x, y, w, h) = normal_rect(rect)
  campy_form.render_controls(form)
  |> list.filter(fn(control) {
    let #(bx, by, bw, bh) = campy_form.bounds(form, control)
    [
      #(bx, by),
      #(bx + bw / 2, by),
      #(bx + bw, by),
      #(bx, by + bh / 2),
      #(bx + bw, by + bh / 2),
      #(bx, by + bh),
      #(bx + bw / 2, by + bh),
      #(bx + bw, by + bh),
    ]
    |> list.any(fn(point) {
      point.0 >= x && point.0 <= x + w && point.1 >= y && point.1 <= y + h
    })
  })
  |> list.map(fn(control) { control.id })
}

/// The id a press inside the selection's outline grabs: the primary
/// selection, or the last one added when nothing is primary. Pressing the gap
/// between two selected components drags the block, like pressing either.
fn selection_grab(state: State, form: Form, x: Int, y: Int) -> String {
  case state.selection {
    [] -> ""
    _ ->
      case union_bounds(form, selection_subtree_ids(state, form)) {
        Some(#(left, top, width, height))
          if x >= left && x <= left + width && y >= top && y <= top + height
        ->
          case state.selected {
            Some(id) -> id
            None -> result.unwrap(list.last(state.selection), "")
          }
        _ -> ""
      }
  }
}

// The pointer arrives in form coordinates, and the form moves with the window
// being dragged: a delta taken in those coordinates chases its own output.
// Adding the window's offset back gives the canvas point, which does not move.
fn canvas_point(state: State, x: Int, y: Int) -> #(Int, Int) {
  let #(window_x, window_y) = window_position(state)
  #(x + window_x, y + window_y)
}

fn resized(
  state: State,
  mode: String,
  last: #(Int, Int),
  x: Int,
  y: Int,
  window: Bool,
) -> State {
  let dx = x - last.0
  let dy = y - last.1
  let next = State(..state, last_pointer: #(x, y))
  let next = case window {
    True -> resize_window(next, dx, dy)
    False -> resize_control(next, mode, dx, dy)
  }
  State(..next, gesture: Resizing(mode, #(x, y), window))
}

fn resize_window(state: State, dx: Int, dy: Int) -> State {
  let state = case dx == 0 {
    True -> state
    False -> resize_window_w(state, dx)
  }
  case dy == 0 {
    True -> state
    False -> resize_window_h(state, dy)
  }
}

fn resize_control(state: State, mode: String, dx: Int, dy: Int) -> State {
  let state = case string.contains(mode, "w") && dx != 0 {
    True -> resize_left(state, dx)
    False ->
      case string.contains(mode, "e") && dx != 0 {
        True -> resize_right(state, dx)
        False -> state
      }
  }
  case string.contains(mode, "n") && dy != 0 {
    True -> resize_top(state, dy)
    False ->
      case string.contains(mode, "s") && dy != 0 {
        True -> resize_bottom(state, dy)
        False -> state
      }
  }
}

pub fn pointer_up(state: State, x: Int, y: Int, additive: Bool) -> State {
  case state.gesture {
    Idle -> State(..state, last_pointer: #(x, y))
    Pressing(_, target) -> {
      let released = State(..state, gesture: Idle, last_pointer: #(x, y))
      case additive, target {
        // A modified press on nothing leaves the selection alone.
        True, "" -> released
        True, id -> toggle_in_selection(released, id)
        False, _ -> select(released, target)
      }
    }
    Moving(_) -> State(..end_gesture(state), gesture: Idle, last_click: None)
    Marqueing(_) | Placing(_) -> {
      let #(left, top, width, height) = normal_rect(state.rect)
      let released =
        State(
          ..state,
          rect: #(left, top, width, height),
          gesture: Idle,
          last_pointer: #(x, y),
        )
      let released = State(..released, preview_selection: [])
      case state.gesture {
        Placing(_) -> place_component(released)
        _ ->
          case width > 2 || height > 2 {
            True -> select_frame(released, additive)
            False ->
              case additive {
                True -> released
                False -> select(released, "")
              }
          }
      }
    }
    MovingWindow(_) ->
      State(..select(state, ""), gesture: Idle, last_click: None)
    Resizing(_, _, _) ->
      State(..end_gesture(state), gesture: Idle, last_click: None)
  }
}

// Escape, a window switch, or a lost pointer: drop the gesture without
// committing anything half-finished.
pub fn pointer_cancel(state: State) -> State {
  let idle =
    State(..state, gesture: Idle, rect: #(0, 0, 0, 0), preview_selection: [])
  case state.gesture {
    Idle -> state
    Pressing(_, _) -> idle
    // A cancelled drag goes back to what it started from: no half-moved
    // selection, and no undo entry for a gesture nobody finished.
    Moving(_) | Resizing(_, _, _) -> {
      let next = case state.gesture_base {
        Some(base) -> restore(state, base)
        None -> idle
      }
      State(
        ..next,
        gesture: Idle,
        rect: #(0, 0, 0, 0),
        preview_selection: [],
        gesture_base: None,
        merge_undo: False,
        drop_active: False,
        drop_candidate: "",
        drag_control: None,
      )
    }
    Marqueing(_) | Placing(_) -> idle
    MovingWindow(_) -> idle
  }
}

fn normal_rect(rect: #(Int, Int, Int, Int)) -> #(Int, Int, Int, Int) {
  let #(x, y, w, h) = rect
  #(int.min(x, x + w), int.min(y, y + h), absolute(w), absolute(h))
}

fn absolute(value: Int) -> Int {
  case value < 0 {
    True -> -value
    False -> value
  }
}

/// The marquee/placement rectangle to draw inside the canvas: active, then
/// normalized form-local x/y/w/h.
pub fn marquee_rect(state: State) -> #(Bool, Int, Int, Int, Int) {
  case state.gesture {
    Marqueing(_) | Placing(_) -> {
      let #(x, y, w, h) = normal_rect(state.rect)
      #(True, x, y, w, h)
    }
    _ -> #(False, 0, 0, 0, 0)
  }
}

/// Adds `id` to the selection, or takes it out when it is already in it: a
/// Ctrl/Shift press on a component. The most recently added one becomes the
/// primary (the inspector's subject).
fn toggle_in_selection(state: State, id: String) -> State {
  case list.contains(state.selection, id) {
    True -> {
      let rest = list.filter(state.selection, fn(other) { other != id })
      let primary = case rest {
        [first, ..] -> Some(first)
        [] -> None
      }
      State(
        ..state,
        selected: primary,
        selection: rest,
        status: case list.length(rest) {
          0 -> "Nothing selected"
          1 -> "1 component selected"
          count -> int.to_string(count) <> " components selected"
        },
      )
    }
    False ->
      State(
        ..state,
        selected: Some(id),
        selection: list.append(state.selection, [id]),
        selected_project: False,
        status: int.to_string(list.length(state.selection) + 1)
          <> " components selected",
      )
  }
}

pub fn selected_control(state: State) -> Option(Control) {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> campy_form.find_control(form, id)
    _, _ -> None
  }
}

pub fn selection_label(state: State) -> String {
  case state.selected_project {
    True -> "Project · " <> state.project.title
    False ->
      case selected_control(state) {
        Some(control) ->
          case list.length(state.selection) {
            1 -> campy_form.kind_label(control.kind) <> " · " <> control.name
            count ->
              int.to_string(count)
              <> " selected · "
              <> campy_form.kind_label(control.kind)
              <> " · "
              <> control.name
          }
        None ->
          case active_form(state) {
            Some(form) -> "Window · " <> form.title
            None -> "Window"
          }
      }
  }
}

pub fn is_events_tab(state: State) -> Bool {
  case state.tab {
    Events -> True
    Properties -> False
  }
}

pub fn is_code_view(state: State) -> Bool {
  case state.view {
    CodeView -> True
    FormView -> False
  }
}

fn status(state: State, message: String) -> State {
  State(..state, status: message)
}
