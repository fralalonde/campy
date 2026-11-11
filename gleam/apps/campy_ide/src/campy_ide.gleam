import campy_bootstrap
import campy_bridge as bridge
import campy_form
import campy_form/live_preview
import campy_form/project
import campy_form/workspace
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/state.{
  type State, Events, NoPopup, OpenFile, PickPicture, Preview, Properties,
  SaveAs,
}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

@external(erlang, "campy_host_ffi", "headless_enabled")
fn headless_enabled() -> Bool

@external(erlang, "campy_host_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "campy_ide_dialog_ffi", "open_dialog")
fn native_dialog(
  mode: String,
  initial: String,
) -> Result(Option(String), String)

@external(erlang, "campy_hot_ffi", "reload")
fn hot_reload() -> Result(Int, String)

// Re-enter the loop through a stable external call so a hot-loaded loop is used.
@external(erlang, "campy_hot_ffi", "continue")
fn continue(
  native: bridge.Session,
  session: Int,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  heartbeat: Int,
) -> Nil

pub fn main() {
  case headless_enabled() {
    True -> campy_bootstrap.main()
    False -> native_main()
  }
}

fn native_main() {
  let assert 1 = bridge.protocol_version()
  let workspace = open_workspace()
  let model = state.initial_workspace(workspace)
  let assert Ok(native) = bridge.open_session()
  let assert Ok(session) = bridge.session_id(native)
  let #(model, submitted) = redraw(native, model, 0)
  let last = ide_ui.without_models(ide_ui.snapshot(model))
  case submitted {
    0 -> {
      io.println("Campy IDE failed to start: " <> model.status)
      Nil
    }
    _ -> {
      io.println("Campy IDE opened")
      continue(native, session, model, submitted, 0, last, now_ms())
    }
  }
}

// Campy opens its own workspace, created on first run.
fn open_workspace() -> workspace.Workspace {
  case workspace.load(workspace.default_path) {
    Ok(loaded) -> loaded
    Error(_) -> {
      let default = open_self_project()
      let ws = workspace.new(default)
      let _ = workspace.save(ws)
      ws
    }
  }
}

// Campy opens itself: its own project file, created on first run.
fn open_self_project() -> project.Project {
  case project.load(project.default_path) {
    Ok(loaded) -> loaded
    Error(_) -> {
      let default = project.campy()
      let _ = project.save(default, project.default_path)
      default
    }
  }
}

type IdeStep {
  IdeContinue(model: State, accepted: Int, last: ide_ui.Snapshot)
  IdeStop
}

// The shell is loaded once. Everything after that is property/model updates on
// the live instance — including structural changes — so the window never
// reloads. `submitted`/`accepted` still guard the initial load.
pub fn loop(
  native: bridge.Session,
  session: Int,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  heartbeat: Int,
) -> Nil {
  let event = bridge.poll(100)
  let now = now_ms()
  let heartbeat = case now - heartbeat >= 1000 {
    True -> {
      io.println("BEAM heartbeat; ui generation=" <> int.to_string(accepted))
      now
    }
    False -> heartbeat
  }
  case event {
    None ->
      continue(native, session, model, submitted, accepted, last, heartbeat)
    Some(bridge.NativeEvent(event_session, generation, kind, payload)) ->
      case event_session == session {
        True ->
          case
            loop_ide_event(
              native,
              model,
              accepted,
              last,
              generation,
              kind,
              payload,
            )
          {
            IdeContinue(next, next_accepted, next_last) ->
              continue(
                native,
                session,
                next,
                submitted,
                next_accepted,
                next_last,
                heartbeat,
              )
            IdeStop -> Nil
          }
        False ->
          case preview_event(model, event_session, kind, payload) {
            Some(next) -> {
              let last = sync(native, accepted, next, last)
              continue(
                native,
                session,
                next,
                submitted,
                accepted,
                last,
                heartbeat,
              )
            }
            None ->
              continue(
                native,
                session,
                model,
                submitted,
                accepted,
                last,
                heartbeat,
              )
          }
      }
  }
}

fn reload_native(
  native: bridge.Session,
  model: State,
  accepted: Int,
) -> IdeStep {
  case hot_reload() {
    Error(error) -> {
      let next =
        state.set_status(model, "Reload failed: " <> short_error(error))
      IdeContinue(next, accepted, ide_ui.empty_snapshot())
    }
    Ok(count) -> {
      let next =
        state.set_status(
          model,
          "Reloaded " <> int.to_string(count) <> " Campy modules; refreshing UI",
        )
      case ide_ui.to_slint(next) {
        Error(error) -> {
          let next =
            state.set_status(next, "UI reload failed: " <> short_error(error))
          IdeContinue(next, accepted, ide_ui.empty_snapshot())
        }
        Ok(source) -> {
          let generation = accepted + 1
          case bridge.submit(native, bridge.LoadUi(generation, source)) {
            Ok(_) -> IdeContinue(next, accepted, ide_ui.empty_snapshot())
            Error(error) -> {
              let next =
                state.set_status(
                  next,
                  "UI reload failed: " <> short_error(error),
                )
              IdeContinue(next, accepted, ide_ui.empty_snapshot())
            }
          }
        }
      }
    }
  }
}

fn short_error(text: String) -> String {
  case string.split(text, "\n") {
    [first, ..] -> string.slice(first, 0, 180)
    [] -> "reload failed"
  }
}

fn loop_ide_event(
  native: bridge.Session,
  model: State,
  accepted: Int,
  last: ide_ui.Snapshot,
  generation: Int,
  kind: String,
  payload: String,
) -> IdeStep {
  case kind {
    "closed" -> {
      io.println("Campy window closed: " <> payload)
      IdeStop
    }
    "runtime-failed" -> {
      io.println("Native runtime failed: " <> payload)
      IdeStop
    }
    "command-failed" -> {
      let next = state.set_status(model, "Command rejected: " <> payload)
      case accepted > 0 {
        True -> {
          let last = sync(native, accepted, next, last)
          IdeContinue(next, accepted, last)
        }
        False -> IdeContinue(next, accepted, last)
      }
    }
    "ui-loaded" -> {
      let next_accepted = case generation > accepted {
        True -> generation
        False -> accepted
      }
      let last = sync(native, next_accepted, model, last)
      IdeContinue(model, next_accepted, last)
    }
    _ ->
      case string.starts_with(kind, "callback:") {
        False -> IdeContinue(model, accepted, last)
        True -> {
          let name = string.drop_start(kind, 9)
          case name == "file-quit" {
            True -> {
              let _ = bridge.close_session(native)
              IdeContinue(state.set_status(model, "Closing"), accepted, last)
            }
            False ->
              case accepted > 0 {
                False -> IdeContinue(model, accepted, last)
                True ->
                  case name == "reload-code" {
                    True -> reload_native(native, model, accepted)
                    False -> {
                      let next = dispatch(model, name, payload)
                      let _ = persist_workspace(model, next)
                      let last = sync(native, accepted, next, last)
                      IdeContinue(next, accepted, last)
                    }
                  }
              }
          }
        }
      }
  }
}

fn persist_workspace(before: State, after: State) -> Nil {
  case before.project == after.project && before.workspace == after.workspace {
    False -> {
      let ws = workspace.update_active(after.workspace, after.project)
      let _ = workspace.save(ws)
      Nil
    }
    True -> Nil
  }
}

fn preview_event_label(
  model: State,
  module_id: String,
  payload: String,
) -> String {
  let control_id = case string.split(payload, ":") {
    [id, ..] -> id
    [] -> payload
  }
  case project.find_module(model.project, module_id) {
    Some(module) ->
      case campy_form.find_control(module.form, control_id) {
        Some(control) ->
          case campy_form.handler_name(control) {
            Some(handler) -> "Event: " <> handler
            None -> "Event: " <> payload
          }
        None -> "Event: " <> payload
      }
    None -> "Event: " <> payload
  }
}

fn preview_event(
  model: State,
  event_session: Int,
  kind: String,
  payload: String,
) -> Option(State) {
  case model.preview {
    Some(preview) if preview.id == event_session ->
      case kind {
        "ui-loaded" -> Some(state.set_status(model, "App running"))
        "closed" ->
          Some(
            state.set_preview(model, None)
            |> state.set_status("App stopped"),
          )
        "command-failed" ->
          Some(state.set_status(model, "App error: " <> payload))
        _ ->
          case kind == "callback:event" {
            True ->
              Some(state.set_status(
                model,
                preview_event_label(model, preview.module, payload),
              ))
            False -> None
          }
      }
    _ -> None
  }
}

fn redraw(
  native: bridge.Session,
  model: State,
  generation: Int,
) -> #(State, Int) {
  case ide_ui.to_slint(model) {
    Error(error) -> #(state.set_status(model, "UI: " <> error), generation)
    Ok(source) -> {
      let next = generation + 1
      case bridge.submit(native, bridge.LoadUi(next, source)) {
        Ok(_) -> #(model, next)
        Error(error) -> #(state.set_status(model, "UI: " <> error), generation)
      }
    }
  }
}

// Push scalar changes plus any model whose contents changed.
fn sync(
  native: bridge.Session,
  generation: Int,
  model: State,
  last: ide_ui.Snapshot,
) -> ide_ui.Snapshot {
  let next = ide_ui.snapshot(model)
  submit_changes(native, generation, ide_ui.diff(last.scalars, next.scalars))
  case next.projects == last.projects {
    False ->
      submit_model(
        native,
        generation,
        "project-items",
        ide_ui.projects_wire(next.projects),
      )
    True -> Nil
  }
  case next.modules == last.modules {
    False ->
      submit_model(
        native,
        generation,
        "module-items",
        ide_ui.modules_wire(next.modules),
      )
    True -> Nil
  }
  case next.tabs == last.tabs {
    False ->
      submit_model(native, generation, "tab-items", ide_ui.tabs_wire(next.tabs))
    True -> Nil
  }
  case next.controls == last.controls {
    False ->
      submit_model(
        native,
        generation,
        "control-items",
        ide_ui.controls_wire(next.controls),
      )
    True -> Nil
  }
  case next.code == last.code {
    False ->
      submit_model(
        native,
        generation,
        "code-lines",
        ide_ui.code_wire(next.code),
      )
    True -> Nil
  }
  next
}

fn submit_changes(
  native: bridge.Session,
  generation: Int,
  changes: List(ide_ui.Update),
) -> Nil {
  list.each(changes, fn(change) {
    let command = case change {
      ide_ui.TextUpdate(name, value) -> bridge.SetText(generation, name, value)
      ide_ui.BoolUpdate(name, value) -> bridge.SetBool(generation, name, value)
      ide_ui.IntUpdate(name, value) -> bridge.SetInt(generation, name, value)
      ide_ui.ScalarIntUpdate(name, value) ->
        bridge.SetInt(generation, name, value)
      ide_ui.ColorUpdate(name, value) ->
        bridge.SetColor(generation, name, value)
    }
    let _ = bridge.submit(native, command)
  })
}

fn submit_model(
  native: bridge.Session,
  generation: Int,
  property: String,
  items: List(bridge.WireValue),
) -> Nil {
  let _ = bridge.submit(native, bridge.SetModel(generation, property, items))
  Nil
}

fn dispatch(model: State, name: String, payload: String) -> State {
  case name {
    "add-component" -> add_component(model, payload)
    "undo" -> state.undo(model)
    "redo" -> state.redo(model)
    "copy-component" -> state.copy_selected(model)
    "cut-component" -> state.cut_selected(model)
    "paste-component" -> state.paste(model)
    "toggle-view" -> state.toggle_view(model)
    "show-ui" -> state.set_slint_tab(model, False)
    "show-slint" -> state.set_slint_tab(model, True)
    "browse-picture" -> pick_picture(model)
    "open-settings" -> state.set_settings_open(model, True)
    "close-settings" -> state.set_settings_open(model, False)
    "font-selected" -> state.set_font(model, payload)
    "font-size-selected" -> state.set_font_size(model, delta(payload))
    "scheme-selected" ->
      state.set_scheme(model, state.scheme_from_name(payload))
    "move-x" -> state.move_gesture_x(model, delta(payload))
    "move-y" -> state.move_gesture_y(model, delta(payload))
    "resize-w" -> state.resize_gesture_w(model, delta(payload))
    "resize-h" -> state.resize_gesture_h(model, delta(payload))
    "set-align" -> state.set_align(model, state.align_from_name(payload))
    "set-layout-free" -> state.set_layout(model, campy_form.Free)
    "set-layout-column" -> state.set_layout(model, campy_form.Column)
    "set-layout-row" -> state.set_layout(model, campy_form.Row)
    "select" -> state.select(model, payload)
    "field-name" -> state.commit_field(model, "name", payload)
    "field-text" -> state.commit_field(model, "text", payload)
    "field-x" -> state.commit_field(model, "x", payload)
    "field-y" -> state.commit_field(model, "y", payload)
    "field-w" -> state.commit_field(model, "w", payload)
    "field-h" -> state.commit_field(model, "h", payload)
    "toggle-enabled" -> state.toggle_field(model, "enabled", payload == "true")
    "toggle-visible" -> state.toggle_field(model, "visible", payload == "true")
    "field-title" -> state.commit_field(model, "title", payload)
    "field-width" -> state.commit_field(model, "width", payload)
    "field-height" -> state.commit_field(model, "height", payload)
    "tab-properties" -> state.set_tab(model, Properties)
    "tab-events" -> state.set_tab(model, Events)
    "edit-event" -> state.open_event(model, payload)
    "delete-selected" -> state.delete_selected(model)
    "editor-view" -> state.leave_edit(model)
    "editor-edit" -> state.enter_edit(model)
    "code-apply" -> state.apply_code(model, payload)
    "view-form" -> state.set_view(model, state.FormView)
    "view-code" -> state.set_view(model, state.CodeView)
    "open-module" -> state.open_module(model, payload)
    "tab-module" -> state.activate_module(model, payload)
    "close-module" -> state.close_module(model, payload)
    "new-module" -> state.new_module(model)
    "switch-project" -> state.switch_project(model, payload)
    "new-project" -> state.create_project(model)
    "delete-project" -> state.delete_active_project(model)
    "file-new" -> state.create_project(model)
    "file-new-module" -> state.new_module(model)
    "file-open" -> open_with_dialog(model)
    "file-save" -> save_current(model)
    "file-save-as" -> save_as_with_dialog(model)
    "popup-accept" -> popup_accept(model, payload)
    "file-cancel" -> state.set_popup(model, NoPopup)
    "run-app" -> run_form(model)
    "update-app" -> update_app(model)
    "stop-app" -> stop_form(model)
    _ -> model
  }
}

fn add_component(model: State, key: String) -> State {
  case campy_form.kind_from_key(key) {
    Some(kind) -> state.add(model, kind)
    None -> model
  }
}

fn delta(payload: String) -> Int {
  case int.parse(payload) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

fn save_current(model: State) -> State {
  case project.save_current(model.project) {
    Ok(saved) ->
      state.set_saved(model, saved)
      |> state.set_status("Saved " <> saved.path)
    Error(error) -> state.set_status(model, "Save failed: " <> error)
  }
}

// System dialogs are preferred; the in-window dialog is the portable fallback.
fn open_with_dialog(model: State) -> State {
  case native_dialog("open", model.project.path) {
    Ok(Some(path)) -> open_path(model, path)
    Ok(None) -> state.set_status(model, "Open cancelled")
    Error(_) -> state.set_popup(model, OpenFile)
  }
}

fn save_as_with_dialog(model: State) -> State {
  case native_dialog("save", model.project.path) {
    Ok(Some(path)) -> save_path(model, path)
    Ok(None) -> state.set_status(model, "Save cancelled")
    Error(_) -> state.set_popup(model, SaveAs)
  }
}

fn pick_picture(model: State) -> State {
  let initial = case state.selected_control(model) {
    Some(control) -> control.text
    None -> ""
  }
  case native_dialog("picture", initial) {
    Ok(Some(path)) ->
      state.commit_field(model, "text", path)
      |> state.set_status("Picture set to " <> path)
    Ok(None) -> state.set_status(model, "Picture selection cancelled")
    Error(_) -> state.set_popup(model, PickPicture)
  }
}

fn open_path(model: State, path: String) -> State {
  case project.load(path) {
    Ok(loaded) -> state.open_project(model, loaded)
    Error(error) -> state.set_status(model, "Open failed: " <> error)
  }
}

fn save_path(model: State, path: String) -> State {
  case project.save(model.project, path) {
    Ok(saved) ->
      state.set_saved(model, saved)
      |> state.set_status("Saved " <> path)
    Error(error) -> state.set_status(model, "Save failed: " <> error)
  }
}

fn popup_accept(model: State, path: String) -> State {
  case model.popup {
    OpenFile ->
      case project.load(path) {
        Ok(loaded) ->
          state.set_project(model, loaded)
          |> state.set_popup(NoPopup)
          |> state.set_status("Opened " <> path)
        Error(error) -> state.set_status(model, "Open failed: " <> error)
      }
    SaveAs ->
      case project.save(model.project, path) {
        Ok(saved) ->
          state.set_saved(model, saved)
          |> state.set_popup(NoPopup)
          |> state.set_status("Saved " <> path)
        Error(error) -> state.set_status(model, "Save failed: " <> error)
      }
    PickPicture ->
      state.commit_field(model, "text", path)
      |> state.set_popup(NoPopup)
      |> state.set_status("Picture set to " <> path)
    NoPopup -> model
  }
}

fn run_form(model: State) -> State {
  case model.preview {
    Some(_) ->
      state.set_status(model, "App is already running; press F6 to update it")
    None ->
      case state.active_module(model) {
        None -> state.set_status(model, "Open a module first")
        Some(module) ->
          case campy_form.validate(module.form) {
            Error(error) -> state.set_status(model, "Cannot run: " <> error)
            Ok(_) -> open_preview(model, module)
          }
      }
  }
}

fn open_preview(model: State, module: project.Module) -> State {
  case bridge.open_session() {
    Error(error) -> state.set_status(model, "Cannot run: " <> error)
    Ok(preview_session) ->
      case bridge.session_id(preview_session) {
        Error(error) -> {
          let _ = bridge.close_session(preview_session)
          state.set_status(model, "Cannot run: " <> error)
        }
        Ok(id) ->
          case
            bridge.submit(
              preview_session,
              bridge.LoadUi(1, live_preview.to_slint()),
            )
          {
            Error(error) -> {
              let _ = bridge.close_session(preview_session)
              state.set_status(model, "Cannot run: " <> error)
            }
            Ok(_) ->
              case
                live_preview_ui.apply(
                  preview_session,
                  live_preview.snapshot(module.form),
                )
              {
                Error(error) -> {
                  let _ = bridge.close_session(preview_session)
                  state.set_status(model, "Cannot run: " <> error)
                }
                Ok(_) ->
                  state.set_preview(
                    model,
                    Some(Preview(preview_session, id, module.id)),
                  )
                  |> state.set_status("Starting " <> module.name)
              }
          }
      }
  }
}

// F6: push the active module's form into the already-running app window. The
// Slint shell and session stay; only the model/properties change.
fn update_app(model: State) -> State {
  case model.preview {
    None -> run_form(model)
    Some(preview) ->
      case state.active_module(model) {
        None -> state.set_status(model, "Open a module first")
        Some(module) ->
          case campy_form.validate(module.form) {
            Error(error) -> state.set_status(model, "Cannot update: " <> error)
            Ok(_) ->
              case
                live_preview_ui.apply(
                  preview.session,
                  live_preview.snapshot(module.form),
                )
              {
                Ok(_) ->
                  state.set_preview(
                    model,
                    Some(Preview(preview.session, preview.id, module.id)),
                  )
                  |> state.set_status("App updated — " <> module.name)
                Error(_) -> {
                  let _ = bridge.close_session(preview.session)
                  state.set_preview(model, None)
                  |> state.set_status(
                    "App window is gone; press F6 to start it",
                  )
                }
              }
          }
      }
  }
}

fn stop_form(model: State) -> State {
  case model.preview {
    None -> state.set_status(model, "Form is not running")
    Some(preview) -> {
      let _ = bridge.close_session(preview.session)
      state.set_preview(model, None)
      |> state.set_status("Form stopped")
    }
  }
}
