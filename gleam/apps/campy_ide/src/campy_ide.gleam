import campy_bootstrap
import campy_bridge as bridge
import campy_ccl
import campy_form
import campy_form/project
import campy_form/workspace
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/mcp
import campy_ide/shell
import campy_ide/state.{
  type Popup, type State, Events, NoPopup, OpenFile, PickPicture,
  PickProjectIcon, Preview, Properties, SaveAs,
}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

@external(erlang, "campy_host_ffi", "headless_enabled")
fn headless_enabled() -> Bool

@external(erlang, "campy_host_ffi", "debug_view")
fn debug_view_env() -> String

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
  let assert 2 = bridge.protocol_version()
  let #(workspace, note) = open_workspace()
  let model = state.initial_workspace(workspace)
  let model = case note {
    "" -> model
    text -> state.log_console(model, text) |> state.set_status(text)
  }
  let assert Ok(native) = bridge.open_session()
  let assert Ok(session) = bridge.session_id(native)
  // The debug view runs after the IDE has claimed its session: a knob that
  // starts a preview must not take the initial session id for itself.
  let model = debug_view(model)
  // The handler-code language server starts with the IDE; failures degrade
  // gracefully (Campy's own completion items still work).
  let _ = case bridge.lsp_start(".") {
    Ok(lsp) -> lsp_put(lsp)
    Error(_) -> Nil
  }
  // One `LoadUi` of the whole shell. `ui-loaded` is the completion barrier:
  // content the document cannot carry (console scrollback, editor buffer,
  // diagnostic marks) is replayed by the first sync.
  case load_snapshot(native, 0, ide_ui.snapshot(model)) {
    Error(error) -> io.println("Campy IDE failed to start: " <> error)
    Ok(#(submitted, baseline)) -> {
      io.println("Campy IDE opened")
      continue(native, session, model, submitted, 0, baseline, now_ms())
    }
  }
}

// Campy opens its own workspace, created on first run. A rejected workspace
// (an older codec, which has no upgrade chain) starts a fresh one with one
// console line — never a crash.
fn open_workspace() -> #(workspace.Workspace, String) {
  case workspace.load(workspace.default_path) {
    Ok(loaded) -> #(migrate_workspace(loaded), "")
    Error(error) -> #(
      new_workspace(),
      "Workspace reset (" <> short_error(error) <> ")",
    )
  }
}

fn new_workspace() -> workspace.Workspace {
  let default = open_self_project()
  let ws = workspace.new(default)
  let _ = workspace.save(ws)
  ws
}

/// `CAMPY_UI_DEBUG_VIEW=settings|agent|project|events|code` opens one of the
/// states a manual pass would otherwise have to click into, so a validation run
/// can screenshot startup: a debugging aid, not a feature.
fn debug_view(model: State) -> State {
  case debug_view_env() {
    "settings" -> state.set_settings_open(model, True)

    "code" -> state.set_view(model, state.CodeView)
    "light" -> state.set_scheme(model, state.Light)
    "select" -> state.select(model, "pet-button")
    "multi" ->
      state.select(model, "pet-button")
      |> state.pointer_down(266, 252)
      |> state.pointer_up(266, 252, True)
    "run" -> run_form(model)
    // Run, then update the running app once: the F7 path end to end.
    "run-update" -> update_app(run_form(model))
    "events" -> state.set_tab(state.select(model, "pet-button"), state.Events)
    _ -> model
  }
}

fn load_workspace() -> workspace.Workspace {
  open_workspace().0
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
  IdeContinue(
    model: State,
    submitted: Int,
    accepted: Int,
    last: ide_ui.Snapshot,
  )
  IdeStop
}

// The shell is loaded once (`LoadUi`) and every later change is a granular op
// against the live generation. `submitted` is the newest requested generation
// and `accepted` the one the renderer confirmed; `last` is the diff baseline —
// the view the document currently displays, minus the content only ops can
// feed (see `ide_ui.without_content`).
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
  let model = state.ensure_current_format(model, load_workspace)
  case mcp.next_request() {
    Some(#(handle, tool, arg)) -> {
      let #(next, text, is_error) = mcp_handle(model, tool, arg)
      let _ = mcp.reply(handle, text, is_error)
      let #(last, submitted, accepted) =
        sync(native, submitted, accepted, next, last)
      continue(native, session, next, submitted, accepted, last, heartbeat)
    }
    None -> {
      let event = bridge.poll(100)
      let now = now_ms()
      let heartbeat = case now - heartbeat >= 1000 {
        True -> {
          io.println(
            "BEAM heartbeat; ui generation="
            <> int.to_string(accepted)
            <> " sessions="
            <> int.to_string(bridge.active_sessions()),
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
                  submitted,
                  accepted,
                  last,
                  generation,
                  kind,
                  payload,
                )
              {
                IdeContinue(next, next_submitted, next_accepted, next_last) ->
                  continue(
                    native,
                    session,
                    next,
                    next_submitted,
                    next_accepted,
                    next_last,
                    heartbeat,
                  )
                IdeStop -> Nil
              }
            False ->
              case preview_event(model, event_session, kind, payload) {
                Some(next) -> {
                  let #(last, submitted, accepted) =
                    sync(native, submitted, accepted, next, last)
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

// ---------------------------------------------------------------------------
// Generations, loading and the op sync
// ---------------------------------------------------------------------------

fn submit_commands(
  native: bridge.Session,
  commands: List(bridge.Command),
) -> Result(Nil, String) {
  list.fold(commands, Ok(Nil), fn(acc, command) {
    use _ <- result.try(acc)
    bridge.submit(native, command)
  })
}

/// Submit a fresh `LoadUi` for `view` at the next generation. Returns the new
/// generation and the diff baseline the loaded document starts from.
fn load_snapshot(
  native: bridge.Session,
  submitted: Int,
  view: ide_ui.Snapshot,
) -> Result(#(Int, ide_ui.Snapshot), String) {
  let generation = submitted + 1
  case
    submit_commands(native, ide_ui.commands(generation, [ide_ui.Reload(view)]))
  {
    Ok(_) -> Ok(#(generation, ide_ui.without_content(view)))
    Error(error) -> Error(error)
  }
}

fn has_reload(ops: List(ide_ui.UiOp)) -> Bool {
  list.any(ops, fn(op) {
    case op {
      ide_ui.Reload(_) -> True
      _ -> False
    }
  })
}

// Move the live document to `model`: granular ops against the accepted
// generation, or a fresh LoadUi when only a rebuild can express the change.
fn sync(
  native: bridge.Session,
  submitted: Int,
  accepted: Int,
  model: State,
  last: ide_ui.Snapshot,
) -> #(ide_ui.Snapshot, Int, Int) {
  let next = ide_ui.snapshot(model)
  let ops = ide_ui.ops(last, next)
  case has_reload(ops) {
    True ->
      case load_snapshot(native, submitted, next) {
        Ok(#(generation, baseline)) -> #(baseline, generation, accepted)
        Error(_) -> #(last, submitted, accepted)
      }
    False ->
      case submitted > accepted {
        // A load is in flight; the next `ui-loaded` syncs from its baseline.
        True -> #(last, submitted, accepted)
        False -> {
          let _ = submit_commands(native, ide_ui.commands(accepted, ops))
          #(next, submitted, accepted)
        }
      }
  }
}

fn advance(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
) -> IdeStep {
  let #(last, submitted, accepted) =
    sync(native, submitted, accepted, model, last)
  IdeContinue(model, submitted, accepted, last)
}

fn keep(model: State, submitted: Int, accepted: Int, last: ide_ui.Snapshot) {
  IdeContinue(model, submitted, accepted, last)
}

// F6: hot-swap the Campy beams and rebuild the shell document in place.
fn reload_native(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
) -> IdeStep {
  case hot_reload() {
    Error(error) ->
      advance(
        native,
        state.set_status(model, "Reload failed: " <> short_error(error)),
        submitted,
        accepted,
        last,
      )
    Ok(count) -> {
      // Cross the module boundary on purpose: after the beams swap, the
      // previous campy_ide may still be executing here, and state's freshly
      // loaded ensure_current_format migrates a stale pre-upgrade model before
      // any new code reads its records.
      let next =
        state.ensure_current_format(model, load_workspace)
        |> state.set_status(
          "Reloaded " <> int.to_string(count) <> " Campy modules; refreshing UI",
        )
      case load_snapshot(native, submitted, ide_ui.snapshot(next)) {
        Ok(#(generation, baseline)) ->
          IdeContinue(next, generation, accepted, baseline)
        Error(error) ->
          advance(
            native,
            state.set_status(next, "UI reload failed: " <> short_error(error)),
            submitted,
            accepted,
            last,
          )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Event routing
// ---------------------------------------------------------------------------

fn loop_ide_event(
  native: bridge.Session,
  model: State,
  submitted: Int,
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
      // A failed load leaves `submitted` ahead of the live document; drop it
      // so granular ops resume against the generation that is actually live.
      let next = state.set_status(model, "Command rejected: " <> payload)
      advance(native, next, accepted, accepted, last)
    }
    "ui-loaded" -> {
      let next_accepted = case generation > accepted {
        True -> generation
        False -> accepted
      }
      let next_submitted = case generation > submitted {
        True -> generation
        False -> submitted
      }
      case generation >= submitted {
        True -> advance(native, model, next_submitted, next_accepted, last)
        False -> keep(model, submitted, next_accepted, last)
      }
    }
    // A hover hint from a control with a `hint` prop: status line only.
    "hover" -> {
      let next = state.hover(model, payload)
      advance(native, next, submitted, accepted, last)
    }
    // The window's CSS size: the shell layout stretches to it, so this is a
    // model change like any other and the diff moves the panes with
    // `SetGeometry` (no reload).
    "size" -> {
      let #(width, height) = window_size(payload)
      let next = state.set_window_size(model, width, height)
      advance(native, next, submitted, accepted, last)
    }
    "lsp:completions" -> {
      let next = state.completions_arrived(model, payload)
      advance(native, next, submitted, accepted, last)
    }
    "lsp:diagnostics" -> {
      let next = state.diagnostics_arrived(model, payload)
      advance(native, next, submitted, accepted, last)
    }
    "lsp:ready" -> keep(model, submitted, accepted, last)
    "key" -> on_key(native, model, submitted, accepted, last, payload)
    _ ->
      case string.starts_with(kind, "editor:") {
        True ->
          on_editor_changed(
            native,
            model,
            submitted,
            accepted,
            last,
            kind,
            payload,
          )
        False ->
          case string.starts_with(kind, "console:") {
            True ->
              on_console_input(
                native,
                model,
                submitted,
                accepted,
                last,
                kind,
                payload,
              )
            False ->
              case string.starts_with(kind, "read:") {
                // A `ReadText` reply (the snapshot harness barriers use these).
                True -> keep(model, submitted, accepted, last)
                False ->
                  case string.starts_with(kind, "pointer:") {
                    True ->
                      on_pointer(
                        native,
                        model,
                        submitted,
                        accepted,
                        last,
                        kind,
                        payload,
                      )
                    False ->
                      case control_event(kind) {
                        Some(#(id, event_key)) ->
                          on_control(
                            native,
                            model,
                            submitted,
                            accepted,
                            last,
                            id,
                            event_key,
                            payload,
                          )
                        None -> keep(model, submitted, accepted, last)
                      }
                  }
              }
          }
      }
  }
}

// `control:<wire id>:<event key>` — the protocol-v2 control event envelope.
fn control_event(kind: String) -> Option(#(Int, String)) {
  case string.split(kind, ":") {
    ["control", wire_id, event_key] ->
      case int.parse(wire_id) {
        Ok(id) -> Some(#(id, event_key))
        Error(_) -> None
      }
    _ -> None
  }
}

/// Every fixed shell section name (the emitter's glossary). Widgets that carry
/// ids (`tile:<kind>`, `insp:<key>`) are derived separately.
fn section_names() -> List(String) {
  [
    "menu-bar", "menu-rule", "menu-file", "menu-edit", "menu-settings",
    "palette", "run", "stop", "nav", "nav-projects-title", "project-delete",
    "project-add", "projects-nav", "nav-rule", "nav-modules-title", "module-add",
    "modules-nav", "tab-strip", "tab-close", "canvas", "canvas-title",
    "canvas-form", "selection-rect", "marquee-rect", "canvas-rule", "form-tab",
    "raw-tab", "raw-view", "view-toggle", "code-title", "code-handler",
    "code-view", "completions", "console-pane", "console-title", "console-state",
    "console-clear", "console", "right-pane", "insp-tab-properties",
    "insp-tab-events", "insp-rule", "insp-selection", "insp-delete",
    "project-panel", "project-icon", "project-icon-glyph", "project-icon-choose",
    "project-icon-clear", "project-title-label", "project-title",
    "project-path-label", "project-path", "inspector", "inspector-events",
    "status-bar", "status", "status-path", "settings-panel", "settings-title",
    "settings-font-label", "settings-font", "settings-size-label",
    "settings-size", "settings-scheme-label", "settings-scheme",
    "settings-hints", "settings-close", "agent-panel", "agent-title",
    "agent-mcp", "agent-port-label", "agent-port", "agent-status",
    "agent-endpoint", "agent-note", "agent-close", "project-dialog",
    "project-dialog-title", "project-dialog-body", "project-new", "project-open",
    "project-dialog-cancel", "browser-panel", "browser-title", "browser-home",
    "browser-new-dir", "browser-dir", "browser-up", "browser-entries",
    "browser-name-label", "browser-name", "browser-accept", "browser-cancel",
    "context-menu", "ctx-cut", "ctx-copy", "ctx-paste", "ctx-delete",
    "ctx-align", "align-menu", "align-left", "align-right", "align-center",
    "align-top", "align-bottom", "align-middle", "nav-context", "nav-ctx-remove",
    "nav-ctx-open", "nav-ctx-delete", "nav-ctx-close-tab",
  ]
}

/// The shell name behind a control wire id (`None` for the designed controls
/// inside the canvas and for ids this loop does not route).
pub fn control_name(id: Int) -> Option(String) {
  case list.find(section_names(), fn(name) { campy_form.wire_id(name) == id }) {
    Ok(name) -> Some(name)
    Error(_) ->
      case tile_name(id) {
        Some(name) -> Some(name)
        None -> inspector_name(id)
      }
  }
}

/// A module tab's id (`tab:<module id>`), one per open module. Tabs are
/// emitted per module rather than as a list, so their ids are derived from
/// the open set rather than from a fixed glossary.
fn tab_name(model: State, id: Int) -> Option(String) {
  case
    list.find_map(model.opened, fn(module_id) {
      case campy_form.wire_id("tab:" <> module_id) == id {
        True -> Ok(module_id)
        False -> Error(Nil)
      }
    })
  {
    Ok(module_id) -> Some("tab:" <> module_id)
    Error(_) -> None
  }
}

fn tile_name(id: Int) -> Option(String) {
  case
    list.find_map(campy_ccl.all(), fn(component) {
      case campy_form.wire_id("tile:" <> component.key) == id {
        True -> Ok("tile:" <> component.key)
        False -> Error(Nil)
      }
    })
  {
    Ok(name) -> Some(name)
    Error(_) -> None
  }
}

fn inspector_name(id: Int) -> Option(String) {
  case
    list.find_map(list.append(shell.prop_keys(), shell.event_keys()), fn(key) {
      case campy_form.wire_id("insp:" <> key) == id {
        True -> Ok(key)
        False -> Error(Nil)
      }
    })
  {
    Ok(key) -> Some("insp:" <> key)
    Error(_) -> None
  }
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

fn on_key(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  combo: String,
) -> IdeStep {
  case key_action(combo) {
    None -> keep(model, submitted, accepted, last)
    Some(action) ->
      run_action(native, model, submitted, accepted, last, action, "")
  }
}

// The shell's twenty pre-v2 bindings, plus recovery bindings for the renderer
// gaps Z2.3 reports (menus and lists are not interactive yet, and the pointer
// payload carries no button or modifiers).
pub fn key_action(combo: String) -> Option(String) {
  case combo {
    "ctrl+z" -> Some("undo")
    "ctrl+shift+z" | "ctrl+y" -> Some("redo")
    "ctrl+c" -> Some("copy-component")
    "ctrl+x" -> Some("cut-component")
    "ctrl+v" -> Some("paste-component")
    "delete" -> Some("delete-selected")
    "ctrl+n" -> Some("file-new")
    "ctrl+shift+n" -> Some("file-new-module")
    "ctrl+o" -> Some("file-open")
    "ctrl+s" -> Some("file-save")
    "ctrl+shift+s" -> Some("file-save-as")
    "ctrl+q" -> Some("file-quit")
    "f5" -> Some("run-app")
    "f6" -> Some("reload-code")
    "f7" -> Some("update-app")
    "shift+f5" -> Some("stop-app")
    "ctrl+tab" -> Some("toggle-view")
    "ctrl+space" -> Some("completion-request")
    "escape" -> Some("escape")
    "ctrl+," -> Some("open-settings")
    "ctrl+alt+m" -> Some("open-agent")
    "shift+f10" -> Some("context-menu-key")
    "ctrl+alt+left" -> Some("prev-tab")
    "ctrl+alt+right" -> Some("next-tab")
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// Pointer (designer gestures)
// ---------------------------------------------------------------------------

fn on_pointer(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  kind: String,
  payload: String,
) -> IdeStep {
  case string.split(kind, ":") {
    ["pointer", surface_id, phase] ->
      case int.parse(surface_id) == Ok(shell.section_id("canvas")) {
        False -> keep(model, submitted, accepted, last)
        True ->
          case form_point(model, payload) {
            None -> keep(model, submitted, accepted, last)
            Some(#(x, y)) -> {
              // The payload is `x;y;button;mods`; Ctrl or Shift means "add to
              // the selection" (components and marquee alike).
              let additive = {
                let mods = string.split(payload, ";") |> list.last
                case mods {
                  Ok(mods) ->
                    string.contains(mods, "ctrl")
                    || string.contains(mods, "shift")
                  Error(_) -> False
                }
              }
              let next = case phase {
                "down" -> state.pointer_down(model, x, y)
                "move" -> state.pointer_move(model, x, y)
                "up" -> state.pointer_up(model, x, y, additive)
                _ -> model
              }
              advance(native, next, submitted, accepted, last)
            }
          }
      }
    _ -> keep(model, submitted, accepted, last)
  }
}

// The surface reports window CSS pixels; the form model lives in form-local
// pixels inside the canvas pane and below the module window's title bar.
fn form_point(model: State, payload: String) -> Option(#(Int, Int)) {
  case string.split(payload, ";") {
    [x_text, y_text, ..] -> {
      let #(window_x, window_y) = state.window_position(model)
      let #(width, height) = model.window_size
      let layout = shell.layout(width, height)
      Some(#(
        pixel(x_text) - layout.canvas_x - window_x,
        pixel(y_text) - layout.canvas_y - shell.form_title_height - window_y,
      ))
    }
    _ -> None
  }
}

/// Parses the renderer's `width;height` size report.
fn window_size(payload: String) -> #(Int, Int) {
  case string.split(payload, ";") {
    [width, height] -> #(
      result.unwrap(int.parse(string.trim(width)), 0),
      result.unwrap(int.parse(string.trim(height)), 0),
    )
    _ -> #(0, 0)
  }
}

fn pixel(text: String) -> Int {
  case float.parse(text) {
    Ok(value) -> float.round(value)
    Error(_) -> 0
  }
}

// ---------------------------------------------------------------------------
// Console and editor
// ---------------------------------------------------------------------------

fn on_console_input(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  kind: String,
  payload: String,
) -> IdeStep {
  case string.split(kind, ":") {
    ["console", id, "input"] ->
      case int.parse(id) == Ok(shell.section_id("console")) {
        True ->
          advance(
            native,
            state.console_input(model, payload),
            submitted,
            accepted,
            last,
          )
        False -> keep(model, submitted, accepted, last)
      }
    _ -> keep(model, submitted, accepted, last)
  }
}

// Editor changes auto-commit the buffer into the module source (file writes
// for External modules), keep the language server in sync, and never echo the
// buffer back with `SetCode` — the editor already owns it, so the diff
// baseline advances with the text instead.
fn on_editor_changed(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  kind: String,
  payload: String,
) -> IdeStep {
  case string.split(kind, ":") {
    ["editor", id, "changed"] ->
      case int.parse(id) == Ok(shell.section_id("code-view")) {
        False -> keep(model, submitted, accepted, last)
        True -> {
          let next = state.code_changed(model, payload)
          case state.active_module(next) {
            Some(module) -> {
              let text = state.module_source(module)
              let uri = next.lsp_uri
              case uri != "", lsp_get() {
                True, Ok(lsp) -> {
                  let _ = case model.lsp_uri == uri {
                    True -> bridge.lsp_change(lsp, uri, next.code_version, text)
                    False -> bridge.lsp_open(lsp, uri, text)
                  }
                  Nil
                }
                _, _ -> Nil
              }
            }
            None -> Nil
          }
          let last = ide_ui.with_source(last, ide_ui.code_source_of(next))
          advance(native, next, submitted, accepted, last)
        }
      }
    _ -> keep(model, submitted, accepted, last)
  }
}

// ---------------------------------------------------------------------------
// Shell control events
// ---------------------------------------------------------------------------

fn on_control(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  id: Int,
  event_key: String,
  payload: String,
) -> IdeStep {
  case
    case control_name(id) {
      Some(name) -> Some(name)
      None -> tab_name(model, id)
    }
  {
    None -> keep(model, submitted, accepted, last)
    Some(name) ->
      case control_action(model, name, event_key, payload) {
        ControlKeep -> keep(model, submitted, accepted, last)
        ControlRun(action, arg) ->
          run_action(native, model, submitted, accepted, last, action, arg)
      }
  }
}

type ControlEffect {
  ControlKeep
  ControlRun(action: String, payload: String)
}

fn control_action(
  model: State,
  name: String,
  event_key: String,
  payload: String,
) -> ControlEffect {
  case name {
    "menu-file" -> menu_effect("menu-file", event_key, payload)
    "menu-edit" -> menu_effect("menu-edit", event_key, payload)
    "menu-settings" -> menu_effect("menu-settings", event_key, payload)
    _ -> derived_control(model, name, event_key, payload)
  }
}

/// Control names the shell derives from state rather than from a fixed table:
/// one per palette tile, one per inspector row, one per open module tab.
fn derived_control(
  model: State,
  name: String,
  event_key: String,
  payload: String,
) -> ControlEffect {
  case string.starts_with(name, "tab:") {
    True -> ControlRun("tab-module", string.drop_start(name, 4))
    False ->
      case string.starts_with(name, "tile:") {
        True -> ControlRun("add-component", string.drop_start(name, 5))
        False ->
          case string.starts_with(name, "insp:") {
            True ->
              inspector_effect(string.drop_start(name, 5), event_key, payload)
            False -> section_effect(model, name, event_key, payload)
          }
      }
  }
}

fn menu_effect(
  menu: String,
  event_key: String,
  payload: String,
) -> ControlEffect {
  case event_key {
    "selected" ->
      case menu_action(menu, payload) {
        Some(action) -> ControlRun(action, "")
        None -> ControlKeep
      }
    _ -> ControlKeep
  }
}

fn inspector_effect(
  key: String,
  event_key: String,
  payload: String,
) -> ControlEffect {
  let is_event = list.contains(shell.event_keys(), key)
  let is_row = list.contains(shell.prop_keys(), key)
  case is_row || is_event, event_key {
    False, _ -> ControlKeep
    True, "edited" -> ControlRun("prop-edit", key <> ";" <> payload)
    True, "toggled" -> ControlRun("prop-edit", key <> ";" <> payload)
    True, "selected" -> ControlRun("prop-edit", key <> ";" <> payload)
    True, "clicked" -> ControlRun("prop-open", key)
    True, _ -> ControlKeep
  }
}

fn section_effect(
  model: State,
  name: String,
  event_key: String,
  payload: String,
) -> ControlEffect {
  case event_key {
    "clicked" -> button_action(name)
    "selected" -> list_action(model, name, payload)
    "edited" -> edit_action(name, payload)
    "toggled" -> toggle_action(name, payload)
    _ -> ControlKeep
  }
}

fn button_action(name: String) -> ControlEffect {
  let action = case name {
    "run" -> "run-app"
    "stop" -> "stop-app"
    "project-add" -> "open-project-dialog"
    "project-delete" -> "delete-project"
    "module-add" -> "file-new-module"
    "tab-close" -> "nav-close-tab"
    "view-toggle" -> "toggle-view"
    "form-tab" -> "show-ui"
    "raw-tab" -> "show-slint"
    "console-clear" -> "clear-console"
    "insp-tab-properties" -> "tab-properties"
    "insp-tab-events" -> "tab-events"
    "insp-delete" -> "delete-selected"
    "project-icon-choose" -> "browse-project-icon"
    "project-icon-clear" -> "clear-project-icon"
    "settings-close" -> "close-settings"
    "agent-close" -> "close-agent"
    "project-new" -> "dialog-new-project"
    "project-open" -> "dialog-open-project"
    "project-dialog-cancel" -> "close-project-dialog"
    "browser-home" -> "browser-home"
    "browser-new-dir" -> "browser-new-dir"
    "browser-up" -> "browser-up"
    "browser-accept" -> "browser-accept"
    "browser-cancel" -> "file-cancel"
    "ctx-cut" -> "context-cut"
    "ctx-copy" -> "context-copy"
    "ctx-paste" -> "context-paste"
    "ctx-delete" -> "context-delete"
    "ctx-align" -> "open-align"
    "nav-ctx-remove" -> "nav-delete"
    "nav-ctx-delete" -> "nav-delete"
    "nav-ctx-close-tab" -> "nav-close-tab"
    _ -> ""
  }
  case action {
    "" -> ControlKeep
    action -> ControlRun(action, "")
  }
}

fn list_action(model: State, name: String, payload: String) -> ControlEffect {
  case name {
    "projects-nav" ->
      case
        list.find(model.workspace.projects, fn(item) { item.title == payload })
      {
        Ok(item) -> ControlRun("switch-project", item.path)
        Error(_) -> ControlKeep
      }
    "modules-nav" ->
      case
        list.find(model.project.modules, fn(module) { module.name == payload })
      {
        Ok(module) -> ControlRun("open-module", module.id)
        Error(_) -> ControlKeep
      }
    "browser-entries" ->
      case model.browser {
        Some(browser) ->
          case list.find(browser.entries, fn(entry) { entry.name == payload }) {
            Ok(entry) ->
              ControlRun(
                "browser-pick",
                entry.name <> ";" <> bool_bit(entry.is_dir),
              )
            Error(_) -> ControlKeep
          }
        None -> ControlKeep
      }
    "completions" ->
      case completion_index(model, payload) {
        Some(index) -> ControlRun("completion-click", int.to_string(index))
        None -> ControlKeep
      }
    "settings-font" -> ControlRun("font-selected", payload)
    "settings-size" -> ControlRun("font-size-selected", payload)
    "settings-scheme" -> ControlRun("scheme-selected", payload)
    _ -> ControlKeep
  }
}

fn edit_action(name: String, payload: String) -> ControlEffect {
  case name {
    "project-title" -> ControlRun("field-project-title", payload)
    "agent-port" -> ControlRun("mcp-port", payload)
    "browser-name" -> ControlRun("browser-set-name", payload)
    _ -> ControlKeep
  }
}

fn toggle_action(name: String, payload: String) -> ControlEffect {
  case name {
    "settings-hints" -> ControlRun("toggle-hints", payload)
    "agent-mcp" -> ControlRun("toggle-mcp", payload)
    _ -> ControlKeep
  }
}

fn bool_bit(value: Bool) -> String {
  case value {
    True -> "1"
    False -> "0"
  }
}

fn completion_index(model: State, label: String) -> Option(Int) {
  completion_index_loop(model.completions, label, 0)
}

fn completion_index_loop(
  items: List(state.Completion),
  label: String,
  index: Int,
) -> Option(Int) {
  case items {
    [] -> None
    [item, ..rest] ->
      case item.label == label {
        True -> Some(index)
        False -> completion_index_loop(rest, label, index + 1)
      }
  }
}

// Menu labels are the old item titles verbatim, shortcut suffix included.
pub fn menu_action(menu: String, label: String) -> Option(String) {
  let title = case string.split(label, "    ") {
    [title, ..] -> title
    [] -> label
  }
  case menu, title {
    "menu-file", "New project" -> Some("file-new")
    "menu-file", "New module" -> Some("file-new-module")
    "menu-file", "Open…" -> Some("file-open")
    "menu-file", "Save" -> Some("file-save")
    "menu-file", "Save As…" -> Some("file-save-as")
    "menu-file", "Quit" -> Some("file-quit")
    "menu-edit", "Undo" -> Some("undo")
    "menu-edit", "Redo" -> Some("redo")
    "menu-edit", "Copy component" -> Some("copy-component")
    "menu-edit", "Cut component" -> Some("cut-component")
    "menu-edit", "Paste component" -> Some("paste-component")
    "menu-edit", "Delete component" -> Some("delete-selected")
    "menu-edit", "Bring to front" -> Some("order-front")
    "menu-edit", "Move to back" -> Some("order-back")
    "menu-edit", "Update running app" -> Some("update-app")
    "menu-edit", "Reload Campy code" -> Some("reload-code")
    "menu-settings", "Editor…" -> Some("open-settings")
    "menu-settings", "Agent…" -> Some("open-agent")
    _, _ -> None
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

fn run_action(
  native: bridge.Session,
  model: State,
  submitted: Int,
  accepted: Int,
  last: ide_ui.Snapshot,
  action: String,
  payload: String,
) -> IdeStep {
  case action {
    "file-quit" -> {
      let _ = bridge.close_session(native)
      advance(
        native,
        state.set_status(model, "Closing"),
        submitted,
        accepted,
        last,
      )
    }
    "reload-code" -> reload_native(native, model, submitted, accepted, last)
    "escape" -> advance(native, escape(model), submitted, accepted, last)
    "completion-request" -> {
      let next = dispatch(model, action, payload)
      let #(line, col) = next.caret
      let _ = request_completions(next, line, col)
      advance(native, next, submitted, accepted, last)
    }
    _ -> {
      let next = dispatch(model, action, payload)
      let _ = persist_workspace(model, next)
      advance(native, next, submitted, accepted, last)
    }
  }
}

// Escape dismisses every transient overlay and abandons a half-finished
// gesture: dialogs, the file browser, a pending placement, menus, popups.
fn escape(model: State) -> State {
  let model =
    model
    |> state.pointer_cancel
    |> state.set_settings_open(False)
    |> state.set_agent_open(False)
    |> state.set_project_dialog_open(False)
    |> state.close_context_menu
    |> state.nav_context_close
    |> state.completion_close
  case model.popup {
    NoPopup -> model
    _ -> state.browser_cancel(model)
  }
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
  wire_id: Int,
  event_key: String,
) -> String {
  case project.find_module(model.project, module_id) {
    Some(module) ->
      case campy_form.find_control_by_wire_id(module.form, wire_id) {
        Some(control) ->
          "Event: " <> campy_form.handler_name(control, event_key)
        None -> "Event: " <> int.to_string(wire_id) <> ":" <> event_key
      }
    None -> "Event: " <> int.to_string(wire_id) <> ":" <> event_key
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
        "closed" -> {
          // Release the session's registration: the window is gone, and a
          // registration that outlives its window is what made one close look
          // like a session that never opened.
          let _ = bridge.close_session(preview.session)
          Some(
            state.set_preview(model, None)
            |> state.set_status("App stopped")
            |> state.log_console("■ App stopped"),
          )
        }
        "command-failed" ->
          Some(
            state.set_status(model, "App error: " <> payload)
            |> state.log_console("App error: " <> payload),
          )
        _ ->
          case control_event(kind) {
            Some(#(wire_id, event_key)) -> {
              let label =
                preview_event_label(model, preview.module, wire_id, event_key)
              Some(
                state.set_status(model, label)
                |> state.log_console(label),
              )
            }
            None -> None
          }
      }
    _ -> None
  }
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
    "window-move-x" -> state.move_window(model, delta(payload), 0)
    "window-move-y" -> state.move_window(model, 0, delta(payload))
    "window-resize-w" -> state.resize_window_w(model, delta(payload))
    "window-resize-h" -> state.resize_window_h(model, delta(payload))
    "rect-x" -> state.set_rect_x(model, delta(payload))
    "rect-y" -> state.set_rect_y(model, delta(payload))
    "rect-w" -> state.set_rect_w(model, delta(payload))
    "rect-h" -> state.set_rect_h(model, delta(payload))
    "frame-apply" -> state.select_frame(model, False)
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
    "completion-click" -> state.completion_click(model, payload)
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
    "browser-set-name" -> state.browser_set_name(model, payload)
    "browser-home" -> state.browser_home(model)
    "browser-new-dir" -> state.browser_new_dir(model)
    "nav-context-menu" -> state.nav_context_menu(model, payload)
    "nav-context-close" -> state.nav_context_close(model)
    "nav-delete" -> state.nav_delete(model)
    // Close tab acts on the right-clicked module (nav_id); the shell's
    // `tab-close` button has no nav target and closes the active tab.
    "nav-close-tab" ->
      case model.nav_id {
        "" -> state.close_module(model, model.active)
        id -> state.close_module(model, id)
      }
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
    "prev-tab" -> state.cycle_tab(model, -1)
    "next-tab" -> state.cycle_tab(model, 1)
    "context-menu-key" -> context_menu_at_selection(model)
    _ -> model
  }
}

// Shift+F10: the canvas context menu, anchored at the selection (the pointer
// payload carries no button, so right-click cannot open it — reported gap).
fn context_menu_at_selection(model: State) -> State {
  case state.selected_control(model), state.active_form(model) {
    Some(control), Some(form) -> {
      let #(x, y, _w, h) = campy_form.bounds(form, control)
      let #(window_x, window_y) = state.window_position(model)
      let #(width, height) = model.window_size
      let layout = shell.layout(width, height)
      state.open_context_menu(
        model,
        control.id
          <> ";"
          <> int.to_string(layout.canvas_x + window_x + x)
          <> ";"
          <> int.to_string(
          layout.canvas_y + shell.form_title_height + window_y + y + h,
        ),
      )
    }
    _, _ -> state.close_context_menu(model)
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

fn theme_of(model: State) -> String {
  case ide_ui.snapshot(model).theme {
    "light" -> "light"
    _ -> "dark"
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
            live_preview_ui.load(
              preview_session,
              1,
              module.form,
              theme_of(model),
            )
          {
            Error(error) -> {
              let _ = bridge.close_session(preview_session)
              state.set_status(model, "Cannot run: " <> error)
            }
            Ok(_) ->
              state.set_preview(
                model,
                Some(Preview(preview_session, id, module.id, 1)),
              )
              |> state.set_status("Starting " <> module.name)
              |> state.log_console("▶ Running " <> module.name)
          }
      }
  }
}

// F6: push the active module's form into the already-running app window. The
// shell and session stay; only the document is re-loaded at a new generation.
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
                Ok(_) -> {
                  let generation = preview.generation + 1
                  case
                    live_preview_ui.load(
                      preview.session,
                      generation,
                      module.form,
                      theme_of(model),
                    )
                  {
                    Ok(_) ->
                      state.set_preview(
                        model,
                        Some(Preview(
                          preview.session,
                          preview.id,
                          module.id,
                          generation,
                        )),
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
