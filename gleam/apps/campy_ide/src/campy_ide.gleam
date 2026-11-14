import campy_bootstrap
import campy_bridge as bridge
import campy_form
import campy_form/live_preview
import campy_form/project
import campy_form/workspace
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/mcp
import campy_ide/state.{
  type Popup, type State, Events, NoPopup, OpenFile, PickPicture,
  PickProjectIcon, Preview, Properties, SaveAs,
}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

@external(erlang, "campy_lsp_ffi", "put")
fn lsp_put(lsp: bridge.Lsp) -> Nil

@external(erlang, "campy_lsp_ffi", "get")
fn lsp_get() -> Result(bridge.Lsp, Nil)

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
  // The handler-code language server starts with the IDE; failures degrade
  // gracefully (Campy's own completion items still work).
  let _ = case bridge.lsp_start(".") {
    Ok(lsp) -> lsp_put(lsp)
    Error(_) -> Nil
  }
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
    Ok(loaded) -> migrate_workspace(loaded)
    Error(_) -> {
      let default = open_self_project()
      let ws = workspace.new(default)
      let _ = workspace.save(ws)
      ws
    }
  }
}

// Keep existing workspaces working after the self project moved to the root.
fn migrate_workspace(ws: workspace.Workspace) -> workspace.Workspace {
  case workspace.find(ws, project.default_path) {
    Some(_) -> ws
    None ->
      case workspace.find(ws, project.legacy_path) {
        Some(old) -> {
          let moved = move_self_project(old)
          let next = workspace.replace_path(ws, old.path, moved)
          let _ = workspace.save(next)
          next
        }
        None -> ws
      }
  }
}

fn move_self_project(self: project.Project) -> project.Project {
  let moved = project.Project(..self, path: project.default_path)
  let _ = project.save(moved, project.default_path)
  moved
}

// Campy opens itself: its own project file, created on first run.
fn open_self_project() -> project.Project {
  case project.load(project.default_path) {
    Ok(loaded) -> loaded
    Error(_) ->
      case project.load(project.legacy_path) {
        Ok(loaded) -> move_self_project(loaded)
        Error(_) -> {
          let default = project.campy()
          let _ = project.save(default, project.default_path)
          default
        }
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
  // F6 re-enters here (via the external campy_hot_ffi:continue call) with a
  // model that may still have been built by the previous code. Migrate before
  // anything reads it, so a project-format change reloads the workspace from
  // disk instead of touching stale records.
  let model = state.ensure_current_format(model, open_workspace)
  case mcp.next_request() {
    Some(#(handle, tool, arg)) -> {
      let #(next, text, is_error) = mcp_handle(model, tool, arg)
      let _ = mcp.reply(handle, text, is_error)
      let last = sync(native, accepted, next, last)
      continue(native, session, next, submitted, accepted, last, heartbeat)
    }
    None -> {
      let event = bridge.poll(100)
      let now = now_ms()
      let heartbeat = case now - heartbeat >= 1000 {
        True -> {
          io.println(
            "BEAM heartbeat; ui generation=" <> int.to_string(accepted),
          )
          now
        }
        False -> heartbeat
      }
      case event {
        None ->
          continue(native, session, model, submitted, accepted, last, heartbeat)
        Some(bridge.NativeEvent(event_session, generation, kind, payload)) ->
          case event_session == session || string.starts_with(kind, "lsp:") {
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
  }
}

pub fn mcp_handle(
  model: State,
  tool: String,
  arg: String,
) -> #(State, String, Bool) {
  case tool {
    "status" -> #(model, mcp_status_text(model), False)
    "modules" -> #(model, mcp_modules_text(model), False)
    "form" -> #(model, mcp_form_text(model), False)
    "console" -> #(model, state.console_text(model), False)
    "run" -> {
      let next = run_form(model) |> state.log_console("MCP: run")
      #(next, "Run requested", False)
    }
    "stop" -> {
      let next = stop_form(model) |> state.log_console("MCP: stop")
      #(next, "Stop requested", False)
    }
    "update_app" -> {
      let next = update_app(model) |> state.log_console("MCP: update app")
      #(next, "App update requested", False)
    }
    "select" -> {
      let next =
        state.select(model, arg) |> state.log_console("MCP: select " <> arg)
      #(next, "Selected " <> arg, False)
    }
    "set_field" ->
      case string.split(arg, "\t") {
        [id, field, value] -> {
          let next = state.select(model, id)
          let next = state.commit_field(next, field, value)
          let next = state.log_console(next, "MCP: set " <> id <> "." <> field)
          #(next, "Updated " <> id <> "." <> field, False)
        }
        _ -> #(model, "Expected id<TAB>field<TAB>value", True)
      }
    "send_input" -> {
      let next =
        state.console_input(model, arg) |> state.log_console("MCP: input")
      #(next, "Console input accepted", False)
    }
    _ -> #(model, "Unknown MCP tool: " <> tool, True)
  }
}

fn mcp_status_text(model: State) -> String {
  "project: "
  <> model.project.title
  <> "\npath: "
  <> model.project.path
  <> "\nmodule: "
  <> state.active_name(model)
  <> "\nselection: "
  <> state.selection_label(model)
  <> "\nstatus: "
  <> model.status
}

fn mcp_modules_text(model: State) -> String {
  model.project.modules
  |> list.map(fn(module) { module.id <> ": " <> module.name })
  |> string.join("\n")
}

fn mcp_form_text(model: State) -> String {
  case state.active_form(model) {
    None -> "no active form"
    Some(form) -> {
      let header =
        "title: "
        <> form.title
        <> "\nsize: "
        <> int.to_string(form.width)
        <> "x"
        <> int.to_string(form.height)
        <> "\nlayout: "
        <> campy_form.layout_key(form.layout)
        <> "\ncontrols: "
        <> int.to_string(list.length(form.controls))
      let controls =
        form
        |> campy_form.render_controls
        |> list.map(fn(control) {
          control.id
          <> " "
          <> control.name
          <> " ["
          <> campy_form.kind_key(control.kind)
          <> "] x="
          <> int.to_string(control.x)
          <> " y="
          <> int.to_string(control.y)
          <> " w="
          <> int.to_string(control.width)
          <> " h="
          <> int.to_string(control.height)
          <> " parent="
          <> campy_form.parent_of(form, control.id)
        })
      string.join([header, ..controls], "\n")
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
      // Cross the module boundary on purpose: after the beams swap, the
      // previous campy_ide may still be executing here, and state's freshly
      // loaded ensure_current_format migrates a stale pre-upgrade model before
      // any new code reads its records.
      let next =
        state.ensure_current_format(model, open_workspace)
        |> state.set_status(
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

fn toggle_mcp(model: State, enabled: Bool) -> State {
  case enabled {
    False -> {
      let _ = mcp.stop()
      state.set_mcp(model, False, "Stopped")
    }
    True ->
      case mcp.start(model.mcp_port) {
        Ok(_) -> state.set_mcp(model, True, mcp.status())
        Error(error) ->
          state.set_mcp(model, False, "MCP error: " <> short_error(error))
      }
  }
}

fn set_mcp_port(model: State, text: String) -> State {
  case int.parse(text) {
    Ok(port) if port >= 1024 && port <= 65_535 -> {
      let next = state.set_mcp_port(model, port)
      case next.mcp_enabled {
        False -> state.set_mcp(next, False, "Stopped")
        True -> {
          let _ = mcp.stop()
          case mcp.start(port) {
            Ok(_) -> state.set_mcp(next, True, mcp.status())
            Error(error) ->
              state.set_mcp(next, False, "MCP error: " <> short_error(error))
          }
        }
      }
    }
    _ ->
      state.set_mcp(
        model,
        model.mcp_enabled,
        "Port must be between 1024 and 65535",
      )
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
    "lsp:completions" -> {
      let next = state.completions_arrived(model, payload)
      let last = sync(native, accepted, next, last)
      IdeContinue(next, accepted, last)
    }
    "lsp:diagnostics" -> {
      let next = state.diagnostics_arrived(model, payload)
      let last = sync(native, accepted, next, last)
      IdeContinue(next, accepted, last)
    }
    "lsp:ready" -> IdeContinue(model, accepted, last)
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
                    False ->
                      case name == "code-edit" {
                        // Keystrokes auto-commit the buffer into the module
                        // source, retokenize, sync the language server, and
                        // request completions at the caret.
                        True ->
                          on_code_edit(native, model, accepted, last, payload)
                        False ->
                          case name == "completion-accept" {
                            True ->
                              on_completion_accept(
                                native,
                                dispatch(model, name, payload),
                                accepted,
                                last,
                              )
                            False ->
                              case name == "completion-click" {
                                True ->
                                  on_completion_accept(
                                    native,
                                    state.completion_click(model, payload),
                                    accepted,
                                    last,
                                  )
                                False ->
                                  case name == "completion-request" {
                                    True -> {
                                      let next = dispatch(model, name, payload)
                                      let #(line, col) = next.caret
                                      let _ =
                                        request_completions(next, line, col)
                                      IdeContinue(next, accepted, last)
                                    }
                                    False -> {
                                      let next = dispatch(model, name, payload)
                                      let _ = persist_workspace(model, next)
                                      let last =
                                        sync(native, accepted, next, last)
                                      IdeContinue(next, accepted, last)
                                    }
                                  }
                              }
                          }
                      }
                  }
              }
          }
        }
      }
  }
}

// Keystroke flow: update caret and draft, retokenize, keep the language
// server's buffer in sync (didOpen on module change, didChange otherwise),
// and ask for completions at the caret.
fn on_code_edit(
  native: bridge.Session,
  model: State,
  accepted: Int,
  last: ide_ui.Snapshot,
  payload: String,
) -> IdeStep {
  let next = dispatch(model, "code-edit", payload)
  case state.active_module(next) {
    Some(module) -> {
      // The keystroke already committed the buffer to the module source;
      // retokenize and keep the language server in sync (didOpen on the
      // first edit of a session, didChange after that), then ask for
      // completions at the caret.
      let _ = bridge.submit(native, bridge.SetCode(accepted, module.source))
      let uri = next.lsp_uri
      case uri != "", lsp_get() {
        True, Ok(lsp) -> {
          case model.lsp_uri == uri {
            True -> {
              let _ =
                bridge.lsp_change(lsp, uri, next.code_version, module.source)
              Nil
            }
            False -> {
              let _ = bridge.lsp_open(lsp, uri, module.source)
              Nil
            }
          }
          let #(line, col) = next.caret
          let _ = bridge.lsp_completions(lsp, uri, line, col)
          Nil
        }
        _, _ -> Nil
      }
      let last = sync(native, accepted, next, last)
      IdeContinue(next, accepted, last)
    }
    None -> IdeContinue(next, accepted, last)
  }
}

// Apply commits the draft to the module; also push it to the language server.
// The spliced buffer was auto-committed by the state; push it back to the
// editor surface (SetText) and the tokenizer (SetCode).
fn on_completion_accept(
  native: bridge.Session,
  next: State,
  accepted: Int,
  last: ide_ui.Snapshot,
) -> IdeStep {
  case state.active_module(next) {
    Some(module) -> {
      let _ =
        bridge.submit(
          native,
          bridge.SetText(accepted, "code-text", module.source),
        )
      let _ = bridge.submit(native, bridge.SetCode(accepted, module.source))
      Nil
    }
    None -> Nil
  }
  let last = sync(native, accepted, next, last)
  IdeContinue(next, accepted, last)
}

fn request_completions(model: State, line: Int, col: Int) -> Nil {
  case lsp_get(), state.lsp_document_uri(model) {
    Ok(lsp), uri ->
      case uri != "" {
        True -> {
          let _ = bridge.lsp_completions(lsp, uri, line, col)
          Nil
        }
        False -> Nil
      }
    Error(_), _ -> Nil
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
  // Payload is "<control-id>:<event-key>" from the live preview shell.
  case string.split(payload, ":") {
    [control_id, event_key] ->
      case project.find_module(model.project, module_id) {
        Some(module) ->
          case campy_form.find_control(module.form, control_id) {
            Some(control) ->
              "Event: " <> campy_form.handler_name(control, event_key)
            None -> "Event: " <> payload
          }
        None -> "Event: " <> payload
      }
    _ -> "Event: " <> payload
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
        "ui-loaded" ->
          Some(
            state.set_status(model, "App running")
            |> state.log_console("App ready"),
          )
        "closed" ->
          Some(
            state.set_preview(model, None)
            |> state.set_status("App stopped")
            |> state.log_console("■ App stopped"),
          )
        "command-failed" ->
          Some(
            state.set_status(model, "App error: " <> payload)
            |> state.log_console("App error: " <> payload),
          )
        _ ->
          case kind == "callback:event" {
            True -> {
              let label = preview_event_label(model, preview.module, payload)
              Some(
                state.set_status(model, label)
                |> state.log_console(label),
              )
            }
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
  // The code editor's buffer: pushed when the editor surface first appears
  // or when the active module changes — never per keystroke (the shell's
  // TextInput owns the live content while typing).
  case
    next.code_view != last.code_view || next.code_module != last.code_module
  {
    True ->
      case state.active_module(model) {
        Some(module) -> {
          let _ =
            bridge.submit(
              native,
              bridge.SetText(generation, "code-text", module.source),
            )
          let _ =
            bridge.submit(native, bridge.SetCode(generation, module.source))
          Nil
        }
        None -> Nil
      }
    False -> Nil
  }
  case next.props == last.props {
    False ->
      submit_model(
        native,
        generation,
        "prop-items",
        ide_ui.props_wire(next.props),
      )
    True -> Nil
  }
  case next.events == last.events {
    False ->
      submit_model(
        native,
        generation,
        "event-items",
        ide_ui.props_wire(next.events),
      )
    True -> Nil
  }
  case next.completions == last.completions {
    False ->
      submit_model(
        native,
        generation,
        "completion-items",
        ide_ui.completions_wire(next.completions),
      )
    True -> Nil
  }
  case next.diagnostics == last.diagnostics {
    False ->
      submit_model(
        native,
        generation,
        "diag-items",
        ide_ui.diagnostics_wire(next.diagnostics),
      )
    True -> Nil
  }
  case next.browser_items == last.browser_items {
    False ->
      submit_model(
        native,
        generation,
        "browser-items",
        ide_ui.browser_wire(next.browser_items),
      )
    True -> Nil
  }
  case next.console_lines == last.console_lines {
    False ->
      submit_model(
        native,
        generation,
        "console-lines",
        ide_ui.console_wire(next.console_lines),
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
    "console-input" -> state.console_input(model, payload)
    "clear-console" -> state.clear_console(model)
    "browse-picture" -> pick_picture(model)
    "browse-project-icon" -> pick_project_icon(model)
    "clear-project-icon" -> state.set_project_icon(model, "")
    "open-settings" ->
      state.set_agent_open(state.set_settings_open(model, True), False)
    "context-menu" -> state.open_context_menu(model, payload)
    "close-context-menu" -> state.close_context_menu(model)
    "context-copy" -> state.close_context_menu(state.copy_selected(model))
    "context-cut" -> state.close_context_menu(state.cut_selected(model))
    "context-paste" -> state.close_context_menu(state.paste(model))
    "context-delete" -> state.close_context_menu(state.delete_selected(model))
    "open-project-dialog" -> state.set_project_dialog_open(model, True)
    "close-project-dialog" -> state.set_project_dialog_open(model, False)
    "dialog-new-project" ->
      state.set_project_dialog_open(state.create_project(model), False)
    "dialog-open-project" ->
      state.set_project_dialog_open(open_with_dialog(model), False)
    "field-project-title" -> state.commit_project_field(model, "title", payload)
    "open-agent" ->
      state.set_agent_open(state.set_settings_open(model, False), True)
    "close-agent" -> state.set_agent_open(model, False)
    "toggle-mcp" -> toggle_mcp(model, payload == "true")
    "mcp-port" -> set_mcp_port(model, payload)
    "close-settings" -> state.set_settings_open(model, False)
    "font-selected" -> state.set_font(model, payload)
    "font-size-selected" -> state.set_font_size(model, delta(payload))
    "scheme-selected" ->
      state.set_scheme(model, state.scheme_from_name(payload))
    "gesture-start" -> state.begin_gesture(model)
    "gesture-end" -> state.end_gesture(model)
    "move-x" -> state.move_gesture_x(model, delta(payload))
    "move-y" -> state.move_gesture_y(model, delta(payload))
    "resize-left" -> state.resize_left(model, delta(payload))
    "resize-right" -> state.resize_right(model, delta(payload))
    "resize-top" -> state.resize_top(model, delta(payload))
    "resize-bottom" -> state.resize_bottom(model, delta(payload))
    "set-align" -> state.set_align(model, state.align_from_name(payload))
    "set-layout" -> state.set_layout(model, state.layout_from_name(payload))
    "set-container-layout" ->
      state.set_container_layout(model, state.layout_from_name(payload))
    "set-layout-free" -> state.set_layout(model, campy_form.Free)
    "set-layout-column" -> state.set_layout(model, campy_form.Column)
    "set-layout-row" -> state.set_layout(model, campy_form.Row)
    "select" -> state.select(model, payload)
    "toggle-select" -> state.toggle_select(model, payload)
    "drag-start" -> state.begin_drag(model, payload)
    "drag-over-x" -> state.set_drop_x(model, delta(payload))
    "drag-over-y" -> state.update_drop(model, delta(payload))
    "window-move-x" -> state.move_window(model, delta(payload), 0)
    "window-move-y" -> state.move_window(model, 0, delta(payload))
    "window-resize-w" -> state.resize_window_w(model, delta(payload))
    "window-resize-h" -> state.resize_window_h(model, delta(payload))
    "rect-x" -> state.set_rect_x(model, delta(payload))
    "rect-y" -> state.set_rect_y(model, delta(payload))
    "rect-w" -> state.set_rect_w(model, delta(payload))
    "rect-h" -> state.set_rect_h(model, delta(payload))
    "frame-apply" -> state.select_frame(model)
    "place-apply" -> state.place_component(model)
    "cancel-place" -> state.cancel_pending(model)
    "toggle-hints" -> state.set_hints(model, payload == "true")
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
    "field-border" -> state.commit_field(model, "border", payload)
    "field-transparency" -> state.commit_field(model, "transparency", payload)
    "order-front" -> state.bring_to_front(model)
    "order-back" -> state.send_to_back(model)
    "prop-edit" ->
      case string.split_once(payload, ";") {
        Ok(#(key, value)) -> state.apply_prop(model, key, value)
        Error(_) -> model
      }
    "prop-open" ->
      case payload {
        "picture" -> pick_picture(model)
        _ -> state.open_event(model, payload)
      }
    "open-align" -> state.toggle_context_align(model)
    "align-selection" ->
      state.close_context_menu(state.align_selection(model, payload))
    "tab-properties" -> state.set_tab(model, Properties)
    "tab-events" -> state.set_tab(model, Events)
    "edit-event" -> state.open_event(model, payload)
    "delete-selected" -> state.delete_selected(model)
    "code-edit" -> state.code_edit(model, payload)
    "editor-view" -> state.leave_edit(model)

    "completion-move" -> state.completion_move(model, delta(payload))
    "completion-close" -> state.completion_close(model)
    "completion-accept" -> state.completion_accept(model)
    "completion-request" -> state.completion_requested(model)
    "editor-edit" -> state.enter_edit(model)
    "view-form" -> state.set_view(model, state.FormView)
    "view-code" -> state.set_view(model, state.CodeView)
    "open-module" -> state.open_module(model, payload)
    "tab-module" -> state.activate_module(model, payload)
    "close-module" -> state.close_module(model, payload)
    "new-module" -> state.new_module(model)
    "switch-project" -> state.switch_project(model, payload)
    "delete-project" -> state.delete_active_project(model)
    "file-new" -> state.create_project(model)
    "file-new-module" -> state.new_module(model)
    "file-open" -> open_with_dialog(model)
    "file-save" -> save_current(model)
    "file-save-as" -> save_as_with_dialog(model)
    "popup-accept" -> popup_accept(model, payload)
    "file-cancel" -> state.browser_cancel(model)
    "browser-navigate" -> state.browser_navigate(model, payload)
    "browser-up" -> state.browser_up(model)
    "browser-pick" -> state.browser_pick(model, payload)
    "browser-home" -> state.browser_home(model)
    "browser-new-dir" -> state.browser_new_dir(model)
    "nav-context-menu" -> state.nav_context_menu(model, payload)
    "nav-context-close" -> state.nav_context_close(model)
    "nav-delete" -> state.nav_delete(model)
    // Close tab acts on the right-clicked module (nav_id), like nav-delete.
    "nav-close-tab" -> state.close_module(model, model.nav_id)
    "console-goto-line" ->
      case string.split_once(payload, ";") {
        Ok(#(line_text, _)) ->
          state.console_goto(model, case int.parse(line_text) {
            Ok(n) -> n
            Error(_) -> 0
          })
        Error(_) -> model
      }
    "browser-accept" ->
      popup_accept(state.browser_close(model), state.browser_path(model))
    "run-app" -> run_form(model)
    "update-app" -> update_app(model)
    "stop-app" -> stop_form(model)
    _ -> model
  }
}

fn add_component(model: State, key: String) -> State {
  state.arm_component(model, key)
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
    Error(_) ->
      state.browser_open(
        model,
        state.OpenFile,
        "",
        base_name(model.project.path),
      )
  }
}

fn save_as_with_dialog(model: State) -> State {
  case native_dialog("save", model.project.path) {
    Ok(Some(path)) -> save_path(model, path)
    Ok(None) -> state.set_status(model, "Save cancelled")
    Error(_) ->
      state.browser_open(model, state.SaveAs, "", base_name(model.project.path))
  }
}

fn pick_picture(model: State) -> State {
  let initial = case state.selected_control(model) {
    Some(control) -> control.text
    None -> ""
  }
  pick_image(model, initial, PickPicture, "Picture", fn(model, path) {
    state.commit_field(model, "text", path)
  })
}

fn pick_project_icon(model: State) -> State {
  pick_image(
    model,
    model.project.icon,
    PickProjectIcon,
    "Project icon",
    state.set_project_icon,
  )
}

fn pick_image(
  model: State,
  initial: String,
  _fallback: Popup,
  label: String,
  apply: fn(State, String) -> State,
) -> State {
  case native_dialog("picture", initial) {
    Ok(Some(path)) ->
      apply(model, path) |> state.set_status(label <> " set to " <> path)
    Ok(None) -> state.set_status(model, label <> " selection cancelled")
    Error(_) -> state.browser_open(model, PickPicture, "", base_name(initial))
  }
}

fn base_name(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
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
    PickProjectIcon ->
      state.set_project_icon(model, path)
      |> state.set_popup(NoPopup)
      |> state.set_status("Project icon set to " <> path)
    NoPopup -> model
  }
}

// Handler-code compile errors (from the language server) block running and
// are reported to the console.
// Handler-code gate: errors block, warnings are logged but never block.
// Returns the model with warnings already emitted to the console, so callers
// continue from that state.
fn gate_compile_errors(model: State, verb: String) -> Result(State, State) {
  let #(errors, warnings) =
    model.diagnostics
    |> list.partition(fn(diagnostic) {
      let #(_, severity, _) = diagnostic
      severity <= 1
    })
  let model = case warnings {
    [] -> model
    _ ->
      model
      |> state.log_console(
        "⚠ handler code has "
        <> int.to_string(list.length(warnings))
        <> " warning(s)",
      )
      |> list_fold_log(
        list.map(warnings, fn(diagnostic) {
          let #(line, _, message) = diagnostic
          "line " <> int.to_string(line + 1) <> ": " <> message
        }),
      )
  }
  case errors {
    [] -> Ok(model)
    _ -> {
      let logged =
        model
        |> state.log_console(
          "✗ "
          <> verb
          <> " failed: handler code has "
          <> int.to_string(list.length(errors))
          <> " error(s)",
        )
        |> list_fold_log(
          list.map(errors, fn(diagnostic) {
            let #(line, _, message) = diagnostic
            "line " <> int.to_string(line + 1) <> ": " <> message
          }),
        )
      Error(state.set_status(logged, "Fix handler code before running"))
    }
  }
}

fn list_fold_log(model: State, errors: List(String)) -> State {
  list.fold(errors, model, fn(acc, error) { state.log_console(acc, error) })
}

fn run_form(model: State) -> State {
  case gate_compile_errors(model, "Run") {
    Error(blocked) -> blocked
    Ok(model) ->
      case model.preview {
        Some(_) ->
          state.set_status(
            model,
            "App is already running; press F6 to update it",
          )
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
                  |> state.log_console("▶ Running " <> module.name)
              }
          }
      }
  }
}

// F6: push the active module's form into the already-running app window. The
// Slint shell and session stay; only the model/properties change.
fn update_app(model: State) -> State {
  case gate_compile_errors(model, "Update") {
    Error(blocked) -> blocked
    Ok(model) ->
      case model.preview {
        None -> run_form(model)
        Some(preview) ->
          case state.active_module(model) {
            None -> state.set_status(model, "Open a module first")
            Some(module) ->
              case campy_form.validate(module.form) {
                Error(error) ->
                  state.set_status(model, "Cannot update: " <> error)
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
                      |> state.log_console("⟳ Updated " <> module.name)
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
}

fn stop_form(model: State) -> State {
  case model.preview {
    None -> state.set_status(model, "Form is not running")
    Some(preview) -> {
      let _ = bridge.close_session(preview.session)
      state.set_preview(model, None)
      |> state.set_status("Form stopped")
      |> state.log_console("■ App stopped")
    }
  }
}
