import campy_bridge as bridge
import campy_form.{type Control, type Form, type Kind}
import campy_form/project.{type Module, type Project}
import campy_form/workspace.{type Workspace}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Tab {
  Properties
  Events
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
  )
}

pub type Preview {
  Preview(session: bridge.Session, id: Int, module: String)
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
    slint_tab: Bool,
    selected: Option(String),
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
    slint_tab: Bool,
    selected: Option(String),
    tab: Tab,
    editor: Editor,
    active_handler: Option(String),
    highlight: Option(#(Int, Int)),
    editing: Option(Editing),
    preview: Option(Preview),
    popup: Popup,
    undo: List(History),
    redo: List(History),
    merge_undo: Bool,
    clipboard: Option(Clipboard),
    font: String,
    font_size: Int,
    scheme: Scheme,
    settings_open: Bool,
    status: String,
  )
}

pub fn initial(project: Project) -> State {
  initial_workspace(workspace.new(project))
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
    slint_tab: False,
    selected: None,
    tab: Properties,
    editor: View,
    active_handler: None,
    highlight: None,
    editing: None,
    preview: None,
    popup: NoPopup,
    undo: [],
    redo: [],
    merge_undo: False,
    clipboard: None,
    font: "monospace",
    font_size: 13,
    scheme: Dark,
    settings_open: False,
    status: "Ready",
  )
}

fn history(state: State) -> History {
  History(
    state.project,
    state.active,
    state.opened,
    state.view,
    state.slint_tab,
    state.selected,
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
    slint_tab: past.slint_tab,
    selected: past.selected,
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
    preview: state.preview,
    status: "Switched to " <> project.title,
  )
}

pub fn switch_project(state: State, path: String) -> State {
  case workspace.find(state.workspace, path) {
    None -> status(state, "Project not found in the workspace")
    Some(target) if target.path == state.project.path -> state
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
    Some(module) ->
      State(
        ..state,
        active: id,
        opened: list.unique([id, ..state.opened]),
        view: FormView,
        selected: None,
        active_handler: None,
        highlight: None,
        editing: None,
        editor: View,
        status: "Opened " <> module.name,
      )
  }
}

// Switching tab keeps the current Form/Code view; only the module changes.
pub fn activate_module(state: State, id: String) -> State {
  case project.find_module(state.project, id) {
    None -> state
    Some(module) ->
      State(
        ..state,
        active: id,
        opened: list.unique([id, ..state.opened]),
        selected: None,
        active_handler: None,
        highlight: None,
        editing: None,
        editor: View,
        status: "Switched to " <> module.name,
      )
  }
}

pub fn close_module(state: State, id: String) -> State {
  case list.filter(state.opened, fn(open) { open != id }) {
    [] -> status(state, "Cannot close the last tab")
    remaining ->
      case state.active == id {
        False -> State(..state, opened: remaining, status: "Closed tab")
        True -> {
          let next = case remaining {
            [first, ..] -> first
            [] -> ""
          }
          State(
            ..state,
            opened: remaining,
            active: next,
            view: FormView,
            selected: None,
            active_handler: None,
            highlight: None,
            editing: None,
            editor: View,
            status: "Closed tab",
          )
        }
      }
  }
}

pub fn new_module(state: State) -> State {
  let suffix = next_module_suffix(state.project.modules, 1)
  let id = "module-" <> int.to_string(suffix)
  let module =
    project.Module(
      id,
      "Module " <> int.to_string(suffix),
      campy_form.new_form(),
      campy_form.default_source(),
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

pub fn set_slint_tab(state: State, slint_tab: Bool) -> State {
  State(..state, slint_tab: slint_tab)
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
                tab: Properties,
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

pub fn set_tab(state: State, tab: Tab) -> State {
  State(..state, tab: tab)
}

pub fn delete_selected(state: State) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> {
      let next =
        update_active_form(state, fn(_) { campy_form.remove_control(form, id) })
      commit(
        state,
        State(
          ..next,
          selected: None,
          active_handler: None,
          highlight: None,
          editing: None,
          status: "Control deleted",
        ),
      )
    }
    _, _ -> status(state, "Select a control to delete")
  }
}

pub fn commit_field(state: State, field: String, value: String) -> State {
  let next = case state.selected, active_form(state) {
    Some(id), Some(form) -> commit_control_field(state, form, id, field, value)
    None, Some(form) -> commit_form_field(state, form, field, value)
    _, _ -> status(state, "Open a module first")
  }
  commit(state, next)
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
    "x" -> update_axis(state, form, id, field, value, 0, 4095)
    "y" -> update_axis(state, form, id, field, value, 0, 4095)
    "w" -> update_axis(state, form, id, field, value, 1, 4095)
    "h" -> update_axis(state, form, id, field, value, 1, 4095)
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
    Ok(number) if number > 0 && number <= 4096 ->
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
fn move_selected_raw(state: State, dx: Int, dy: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> {
      let ids = campy_form.subtree_ids(form, id)
      let next =
        list.fold(ids, form, fn(acc, control_id) {
          campy_form.update_selected(acc, control_id, fn(control) {
            campy_form.Control(
              ..control,
              x: int.max(0, int.min(4095, control.x + dx)),
              y: int.max(0, int.min(4095, control.y + dy)),
            )
          })
        })
      update_active_form(state, fn(_) { next })
    }
    _, _ -> state
  }
}

pub fn move_selected(state: State, dx: Int, dy: Int) -> State {
  commit(state, move_selected_raw(state, dx, dy))
}

pub fn move_gesture_x(state: State, dx: Int) -> State {
  let committed = commit(state, move_selected_raw(state, dx, 0))
  State(
    ..committed,
    merge_undo: list.length(committed.undo) > list.length(state.undo),
  )
}

pub fn move_gesture_y(state: State, dy: Int) -> State {
  let committed = commit(state, move_selected_raw(state, 0, dy))
  State(..committed, merge_undo: False)
}

fn resize_selected_raw(state: State, dw: Int, dh: Int) -> State {
  case state.selected, active_form(state) {
    Some(id), Some(form) ->
      change_control(state, form, id, fn(control) {
        campy_form.Control(
          ..control,
          width: int.max(8, int.min(4095, control.width + dw)),
          height: int.max(8, int.min(4095, control.height + dh)),
        )
      })
    _, _ -> state
  }
}

pub fn resize_selected(state: State, dw: Int, dh: Int) -> State {
  commit(state, resize_selected_raw(state, dw, dh))
}

pub fn resize_gesture_w(state: State, dw: Int) -> State {
  let committed = commit(state, resize_selected_raw(state, dw, 0))
  State(
    ..committed,
    merge_undo: list.length(committed.undo) > list.length(state.undo),
  )
}

pub fn resize_gesture_h(state: State, dh: Int) -> State {
  let committed = commit(state, resize_selected_raw(state, 0, dh))
  State(..committed, merge_undo: False)
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
    _ -> campy_form.NoAlign
  }
}

pub fn copy_selected(state: State) -> State {
  case selected_control(state), active_form(state) {
    Some(control), Some(form) -> {
      let ids = campy_form.subtree_ids(form, control.id)
      let controls =
        list.filter(form.controls, fn(item) { list.contains(ids, item.id) })
      let parents =
        list.filter(form.parents, fn(entry) { list.contains(ids, entry.0) })
      let aligns =
        list.filter(form.aligns, fn(entry) { list.contains(ids, entry.0) })
      State(
        ..state,
        clipboard: Some(Clipboard(controls, parents, aligns)),
        status: "Copied " <> control.name,
      )
    }
    _, _ -> status(state, "Select a component to copy")
  }
}

pub fn cut_selected(state: State) -> State {
  case selected_control(state) {
    None -> status(state, "Select a component to cut")
    Some(control) -> {
      let copied = copy_selected(state)
      let removed = delete_selected(copied)
      State(..removed, status: "Cut " <> control.name)
    }
  }
}

pub fn paste(state: State) -> State {
  case state.clipboard, active_form(state) {
    Some(Clipboard(controls, parents, aligns)), Some(form) -> {
      let #(form, pasted) =
        campy_form.paste_controls(
          form,
          controls,
          parents,
          aligns,
          adoption_target(state),
        )
      let next = update_active_form(state, fn(_) { form })
      commit(state, case pasted {
        Some(control) ->
          State(
            ..next,
            selected: Some(control.id),
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

pub fn set_settings_open(state: State, open: Bool) -> State {
  State(..state, settings_open: open)
}

pub fn scheme_from_name(name: String) -> Scheme {
  case name {
    "Light" -> Light
    "Solarized" -> Solarized
    _ -> Dark
  }
}

// Open the event handler in the code pane, creating a stub when required.
pub fn open_event(state: State, _key: String) -> State {
  case selected_control(state) {
    None -> status(state, "Select a control first")
    Some(control) ->
      case campy_form.handler_name(control) {
        None -> status(state, "This control has no events")
        Some(handler) ->
          case active_module(state) {
            None -> status(state, "Open a module first")
            Some(module) -> {
              let #(source, start) =
                campy_form.ensure_handler(module.source, handler)
              case campy_form.handler_range(source, start) {
                None -> status(state, "Cannot locate the handler")
                Some(range) -> {
                  let module = project.Module(..module, source: source)
                  commit(
                    state,
                    State(
                      ..state,
                      project: project.update_module(state.project, module),
                      view: CodeView,
                      active_handler: Some(handler),
                      highlight: Some(range),
                      editing: Some(Editing(
                        campy_form.handler_text(source, range),
                        range,
                      )),
                      editor: Edit,
                      status: "Editing " <> handler,
                    ),
                  )
                }
              }
            }
          }
      }
  }
}

pub fn enter_edit(state: State) -> State {
  case state.active_handler, state.highlight {
    Some(_), Some(range) ->
      case active_module(state) {
        Some(module) ->
          State(
            ..state,
            view: CodeView,
            editing: Some(Editing(
              campy_form.handler_text(module.source, range),
              range,
            )),
            editor: Edit,
          )
        None -> state
      }
    _, _ -> status(state, "Select an event in the Inspector first")
  }
}

pub fn leave_edit(state: State) -> State {
  State(..state, editor: View, editing: None)
}

pub fn apply_code(state: State, text: String) -> State {
  case state.editing, active_module(state) {
    Some(Editing(_, range)), Some(module) -> {
      let #(source, next) =
        campy_form.replace_handler(module.source, range, text)
      commit(
        state,
        State(
          ..state,
          project: project.update_module(
            state.project,
            project.Module(..module, source: source),
          ),
          highlight: Some(next),
          editing: None,
          editor: View,
          status: "Handler updated",
        ),
      )
    }
    _, _ -> state
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

pub fn set_preview(state: State, preview: Option(Preview)) -> State {
  State(..state, preview: preview)
}

pub fn selected_control(state: State) -> Option(Control) {
  case state.selected, active_form(state) {
    Some(id), Some(form) -> campy_form.find_control(form, id)
    _, _ -> None
  }
}

pub fn selection_label(state: State) -> String {
  case selected_control(state) {
    Some(control) ->
      campy_form.kind_label(control.kind) <> " · " <> control.name
    None ->
      case active_form(state) {
        Some(form) -> "Window · " <> form.title
        None -> "Window"
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
