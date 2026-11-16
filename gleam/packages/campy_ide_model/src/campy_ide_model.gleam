//// Display-free IDE state.
////
//// The wx shell (`campy_ide_wx`, T1.4) owns no document logic: it renders this
//// state and sends commands here. Everything in this module is pure, so the
//// IDE's behaviour is testable without a display.

import campy_project.{type Module, type Project}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

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

pub fn active_module(state: State) -> Result(Module, String) {
  case state.active {
    None -> Error("no active module")
    Some(slug) -> campy_project.module(state.project, slug)
  }
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
