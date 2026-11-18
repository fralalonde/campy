//// Campy IDE shell on wx.
////
//// Loads a project directory, renders the shell view, and forwards wx events
//// into `campy_ide_model`. Document logic lives in the model; this module
//// builds the view tree, applies its diffs, and fills data-driven panes.
////
//// Run: `CAMPY_PROJECT=examples/demo gleam run` from this directory.
//// Smoke: `CAMPY_WX_SMOKE=1` runs mount/switch/select/close without a loop.

import campy_app
import campy_appgen
import campy_catalog
import campy_design
import campy_ide_model as model
import campy_peer
import campy_project
import campy_runner
import campy_source
import campy_view.{type Node, VBool, VInt, VList, VMap, VText}
import campy_view/diff
import campy_wx
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/system
import gleam/result
import gleam/string

pub fn main() {
  let dir = case campy_wx.getenv("CAMPY_PROJECT") {
    "" -> "../../../examples/demo"
    dir -> dir
  }

  case campy_project.load(dir) {
    Error(error) -> io.println("[ide] cannot load " <> dir <> ": " <> error)
    Ok(project) ->
      case campy_wx.getenv("CAMPY_WX_SMOKE") {
        "1" -> smoke(project, dir)
        _ -> interactive(project, dir)
      }
  }
}

fn interactive(project: campy_project.Project, dir: String) {
  let shell = campy_wx.start("Campy — " <> project.title, 1280, 860)
  let state =
    model.new(project)
    |> model.update(model.Log("Loaded " <> dir))
    |> model.update(model.SetStatus(dir))
  let current_view = view(state)

  let assert Ok(shell) = campy_wx.mount(shell, current_view)
  refresh(shell, None, state)
  loop(shell, state, current_view, dir, NoDrag)
}

fn smoke(project: campy_project.Project, dir: String) {
  let shell = campy_wx.start("Campy — " <> project.title, 1280, 860)
  let started = campy_wx.now_ms()
  let state =
    model.new(project)
    |> model.update(model.Log("Loaded " <> dir))
    |> model.update(model.SetStatus(dir))
  let current_view = view(state)

  let assert Ok(shell) = campy_wx.mount(shell, current_view)
  io.println(
    "[ide] mount " <> int.to_string(campy_wx.now_ms() - started) <> "ms",
  )
  refresh(shell, None, state)

  let previous = state
  let state = case project.modules {
    [_, second, ..] -> model.update(state, model.OpenModule(second.slug))
    _ -> state
  }
  let shell = rebind(shell, current_view, view(state))
  let state = select_first_control(state)
  refresh(shell, Some(previous), state)

  io.println(
    "[ide] active="
    <> active_slug(state)
    <> " selection="
    <> int.to_string(list.length(state.selection)),
  )
  io.println("[ide] smoke ok")
  campy_wx.close(shell)
}

fn rebind(shell: campy_wx.Shell, previous: Node, next: Node) -> campy_wx.Shell {
  case campy_wx.apply(shell, diff.diff(previous, next)) {
    Ok(shell) -> shell
    Error(error) -> {
      io.println("[ide] view error: " <> error)
      shell
    }
  }
}

fn select_first_control(state: model.State) -> model.State {
  case model.active_module(state) {
    Ok(module) ->
      case module.form.view.children {
        [first, ..] -> model.select_controls(state, [first.id])
        [] -> state
      }
    Error(_) -> state
  }
}

fn loop(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
) {
  // Drain the running app's replies before the next wx event.
  let state = poll_app(shell, state, current)
  case campy_wx.next(shell, 100) {
    campy_wx.Closed -> {
      campy_wx.close(shell)
      io.println("[ide] closed")
    }
    campy_wx.Paint(id) -> {
      campy_wx.paint(shell, id)
      loop(shell, state, current, dir, drag)
    }
    campy_wx.Mouse(id, kind, x, y, control) ->
      handle_design_mouse(
        shell,
        state,
        current,
        dir,
        drag,
        id,
        kind,
        x,
        y,
        control,
      )
    campy_wx.Event(id, key, value) ->
      case id {
        "menu-quit" -> {
          campy_wx.close(shell)
          io.println("[ide] quit")
        }
        "tool-run" -> toggle_run(shell, state, current, dir)
        "tool-stop" -> toggle_run(shell, state, current, dir)
        "nodes-start" -> start_peer(shell, state, current, dir)
        "nodes-stop" -> stop_peer(shell, state, current, dir)
        "nodes-deploy" -> deploy_to_peer(shell, state, current, dir)
        "nodes-redeploy" -> redeploy_on_peer(shell, state, current, dir)
        "nodes-app-stop" -> toggle_run(shell, state, current, dir)
        "debug-state" -> dump_state(shell, state, current, dir)
        "debug-trace" -> toggle_trace(shell, state, current, dir)
        "debug-refresh" -> refresh_processes(shell, state, current, dir)
        "menu-help-keys" -> {
          campy_wx.show_message(shell, "Keyboard shortcuts", help_text())
          loop(shell, state, current, dir, drag)
        }
        _ -> {
          let previous = state
          let state = handle(state, dir, id, key, value)
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          // A committed grid edit leaves keyboard focus inside wxGrid's
          // editor, which eats Ctrl+Z and friends. Hand focus back to the
          // canvas so the frame shortcuts keep working.
          case id {
            "inspector" -> campy_wx.focus(shell, "canvas")
            "tabs" -> focus_page(shell, state)
            _ -> Nil
          }
          loop(shell, state, next, dir, NoDrag)
        }
      }

    campy_wx.KeyPressed(key) ->
      handle_key(shell, state, current, dir, drag, key)
    campy_wx.Accelerator(action) ->
      handle_accelerator(shell, state, current, dir, drag, action)
    campy_wx.FrameMoved -> {
      // Reposition screen-anchored chrome after the window moves/resizes, but
      // never fight a live drag preview (child move events can arrive too).
      case drag {
        NoDrag ->
          campy_wx.show_selection(
            shell,
            selection_rect(state),
            list.length(state.selection) == 1,
          )
        _ -> Nil
      }
      loop(shell, state, current, dir, drag)
    }
    campy_wx.Message(message) ->
      case trace_log_text(message) {
        Ok(text) -> {
          io.println("[trace] " <> text)
          let state = model.update(state, model.RunReport(text))
          set_console(shell, state)
          loop(shell, state, current, dir, drag)
        }
        Error(_) -> loop(shell, state, current, dir, drag)
      }
    campy_wx.Idle -> loop(shell, state, current, dir, drag)
  }
}

/// Forward a shell event to the running app when the event's control is part
/// of the published view and declared the key. Returns True when routed.
fn route_live_event(
  state: model.State,
  id: String,
  key: String,
  value: campy_view.Value,
) -> Bool {
  case state.running, state.live_view {
    Some(running), Some(document) ->
      case campy_design.find_node(document.view, id) {
        Some(node) ->
          case list.contains(node.events, key) {
            True -> {
              process.send(
                running.dispatch,
                campy_app.EventReceived(campy_app.Event(
                  control: id,
                  key: key,
                  value: value,
                  generation: 0,
                )),
              )
              True
            }
            False -> False
          }
        None -> False
      }
    _, _ -> False
  }
}

/// Drain the running app's replies into model commands. A `View` reply
/// re-renders the live preview; reports go to the console. The wx loop calls
/// this once per pass, so replies queue while wx events are processed.
fn poll_app(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
) -> model.State {
  case state.running {
    None -> state
    Some(running) ->
      case process.receive(running.reply, 0) {
        Error(_) -> state
        Ok(campy_app.View(document, gen)) -> {
          io.println("[app] view generation " <> int.to_string(gen))
          let first = state.live_view == None
          let previous = state
          let state = model.update(state, model.RunView(document, gen))
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          // Follow the app to the Run page only when it first attaches;
          // later generations must not yank the user off another page.
          case first {
            True -> campy_wx.select_page(shell, "tabs", page_index(state))
            False -> Nil
          }
          poll_app(shell, state, next)
        }
        Ok(campy_app.Report(text)) -> {
          io.println("[app] " <> text)
          let state = model.update(state, model.RunReport(text))
          set_console(shell, state)
          poll_app(shell, state, current)
        }
        Ok(campy_app.Notified(text)) -> {
          io.println("[app] notify: " <> text)
          let state = model.update(state, model.RunReport("notify: " <> text))
          set_console(shell, state)
          poll_app(shell, state, current)
        }
        Ok(campy_app.Version(version)) -> {
          io.println("[app] state version " <> int.to_string(version))
          let state =
            model.update(
              state,
              model.RunReport("app state version " <> int.to_string(version)),
            )
          set_console(shell, state)
          poll_app(shell, state, current)
        }
        Ok(campy_app.Stopped) -> {
          io.println("[ide] app stopped")
          let previous = state
          let state = model.update(state, model.RunStopped)
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          state
        }
      }
  }
}

/// Keyboard dispatch. While the Code or Source page is active the editor keeps
/// its text shortcuts (C/X/V/Z); only Save/Quit and page switching are stolen
/// from it.
fn handle_key(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  key: campy_wx.Key,
) {
  // char_hook handles the editing keys; the accelerator table handles the
  // base keys (save/quit/pages/escape). Ignore the latter here so a key is
  // never applied twice.
  let action = case shortcut(state, key) {
    Save | Quit | ShowFormPage | ShowCodePage | ShowSourcePage | Cancel ->
      NoShortcut
    action -> action
  }
  dispatch_shortcut(shell, state, current, dir, drag, action)
}

fn handle_accelerator(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  action: String,
) {
  dispatch_shortcut(
    shell,
    state,
    current,
    dir,
    drag,
    accelerator_shortcut(action),
  )
}

pub fn accelerator_shortcut(action: String) -> Shortcut {
  case action {
    "save" -> Save
    "quit" -> Quit
    "undo" -> Undo
    "redo" -> Redo
    "cut" -> Cut
    "copy" -> Copy
    "paste" -> Paste
    "duplicate" -> Duplicate
    "delete" -> DeleteControl
    "escape" -> Cancel
    "form" -> ShowFormPage
    "code" -> ShowCodePage
    "source" -> ShowSourcePage
    _ -> NoShortcut
  }
}

fn dispatch_shortcut(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  action: Shortcut,
) {
  case action {
    Quit -> {
      campy_wx.close(shell)
      io.println("[ide] quit")
    }
    NoShortcut -> loop(shell, state, current, dir, drag)
    Cancel -> {
      let previous = state
      let state = cancel_drag(shell, state, drag) |> model.update(model.Disarm)
      let next = view(state)
      let shell = rebind(shell, current, next)
      refresh(shell, Some(previous), state)
      loop(shell, state, next, dir, NoDrag)
    }
    action -> {
      let previous = state
      let state = apply_shortcut(state, dir, action)
      let next = view(state)
      let shell = rebind(shell, current, next)
      refresh(shell, Some(previous), state)
      case action {
        ShowFormPage | ShowCodePage | ShowSourcePage -> focus_page(shell, state)
        _ -> Nil
      }
      loop(shell, state, next, dir, NoDrag)
    }
  }
}

fn focus_page(shell: campy_wx.Shell, state: model.State) -> Nil {
  case state.code_view, state.source_view {
    True, _ -> campy_wx.focus(shell, "code")
    False, True -> campy_wx.focus(shell, "source")
    False, False -> campy_wx.focus(shell, "canvas")
  }
}

fn apply_shortcut(
  state: model.State,
  dir: String,
  action: Shortcut,
) -> model.State {
  case action {
    Save -> save(state, dir)
    Undo -> model.update(state, model.Undo)
    Redo -> model.update(state, model.Redo)
    Copy -> model.update(state, model.CopySelection)
    Cut -> model.update(state, model.CutSelection)
    Paste -> model.update(state, model.Paste)
    Duplicate -> model.update(state, model.DuplicateSelection)
    DeleteControl -> model.update(state, model.DeleteSelection)
    ShowFormPage -> model.update(state, model.ShowForm)
    ShowCodePage -> model.update(state, model.ShowCode)
    ShowSourcePage -> model.update(state, model.ShowSource)
    Cancel | Quit | NoShortcut -> state
  }
}

/// Restore live previews after Escape aborts a gesture. Committed geometry is
/// untouched; only the widgets that were being dragged snap back.
fn cancel_drag(
  shell: campy_wx.Shell,
  state: model.State,
  drag: Drag,
) -> model.State {
  case drag {
    NoDrag -> state
    PlacementDrag(_, _, _) | MarqueeDrag(_, _) -> {
      campy_wx.release_canvas(shell)
      campy_wx.show_marquee(shell, None)
      state
    }
    MoveDrag(items, _, _, _, _, origins) -> {
      list.each(items, fn(item) {
        let #(id, #(rx, ry, rw, rh)) = item
        let #(px, py, pw, ph) =
          preview_in_parent_cached(origins, id, #(rx, ry, rw, rh))
        campy_wx.preview_rect(shell, id, px, py, pw, ph)
      })
      campy_wx.release_canvas(shell)
      campy_wx.thaw_canvas(shell)
      state
    }
    ResizeDrag(drag_id, _, _, _, #(rx, ry, rw, rh), _, origins) -> {
      let #(px, py, pw, ph) =
        preview_in_parent_cached(origins, drag_id, #(rx, ry, rw, rh))
      campy_wx.preview_rect(shell, drag_id, px, py, pw, ph)
      campy_wx.release_canvas(shell)
      campy_wx.thaw_canvas(shell)
      state
    }
  }
}

pub type Shortcut {
  Save
  Quit
  Undo
  Redo
  Copy
  Cut
  Paste
  Duplicate
  DeleteControl
  ShowFormPage
  ShowCodePage
  ShowSourcePage
  Cancel
  NoShortcut
}

/// Pure shortcut mapping (tested without a display). Text-editing shortcuts are
/// ignored while Code/Source is visible so Scintilla keeps them.
pub fn shortcut(state: model.State, key: campy_wx.Key) -> Shortcut {
  let editing = state.code_view || state.source_view

  case key.control, key.alt, key.shift, key.code {
    True, False, _, "q" -> Quit
    True, False, _, "s" -> Save
    True, False, _, "1" -> ShowFormPage
    True, False, _, "2" -> ShowCodePage
    True, False, _, "3" -> ShowSourcePage
    True, False, True, "z" -> Redo
    True, False, False, "z" ->
      case editing {
        True -> NoShortcut
        False -> Undo
      }
    True, False, _, "y" -> Redo
    True, False, False, "c" ->
      case editing {
        True -> NoShortcut
        False -> Copy
      }
    True, False, False, "x" ->
      case editing {
        True -> NoShortcut
        False -> Cut
      }
    True, False, False, "v" ->
      case editing {
        True -> NoShortcut
        False -> Paste
      }
    True, False, False, "d" ->
      case editing {
        True -> NoShortcut
        False -> Duplicate
      }
    False, False, _, "delete" ->
      case state.selection {
        [] -> NoShortcut
        _ -> DeleteControl
      }
    False, False, _, "escape" -> Cancel
    _, _, _, _ -> NoShortcut
  }
}

@external(erlang, "campy_ide_wx_ffi", "make_dir")
fn make_dir(path: String) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "compile_and_load")
fn compile_and_load(dir: String, module: String) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "start_app_on")
fn start_app_on(
  node: String,
  spec: campy_app.Spec,
  reply: process.Subject(campy_app.Reply),
) -> Result(process.Subject(campy_app.Msg), String)

@external(erlang, "campy_ide_wx_ffi", "load_code_on")
fn load_code_on(
  node: String,
  module: String,
  beam_path: String,
) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "pause_on")
fn pause_on(node: String, pid: process.Pid) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "resume_on")
fn resume_on(node: String, pid: process.Pid) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "format_term")
fn format_term(term: a) -> String

@external(erlang, "campy_ide_wx_ffi", "spawn_tracer")
fn spawn_tracer(node: String, master: process.Pid, label: String) -> Dynamic

@external(erlang, "campy_ide_wx_ffi", "trace_send_receive")
fn trace_send_receive(
  node: String,
  pid: process.Pid,
  tracer: Dynamic,
  on: Bool,
) -> Result(Nil, String)

@external(erlang, "campy_ide_wx_ffi", "stop_tracer")
fn stop_tracer(node: String, tracer: Dynamic) -> Nil

@external(erlang, "campy_ide_wx_ffi", "processes_on")
fn processes_on(
  node: String,
) -> Result(List(#(String, Int, Int, String)), String)

@external(erlang, "campy_ide_wx_ffi", "trace_log_text")
fn trace_log_text(message: anything) -> Result(String, Nil)

/// The ebin directories a peer needs for the runtime; paths under the repo
/// root so they resolve on the (local) peer node too.
fn runtime_dirs() -> List(String) {
  let runner = root() <> "/gleam/packages/campy_runner/build/dev/erlang"
  [
    runner <> "/gleam_stdlib/ebin",
    runner <> "/gleam_erlang/ebin",
    runner <> "/gleam_otp/ebin",
    runner <> "/campy_view/ebin",
    runner <> "/campy_app/ebin",
    runner <> "/campy_runner/ebin",
  ]
}

/// The scratch build's app modules.
fn apps_dir() -> String {
  scratch_dir() <> "/build/dev/erlang/campy_apps/ebin"
}

/// The repo root for the scratch app package. `CAMPY_ROOT` wins when set
/// (workspace.py exports it); otherwise it is derived from the process cwd,
/// which is the app package three levels under the repo root.
@external(erlang, "campy_ide_wx_ffi", "cwd")
fn cwd() -> String

fn root() -> String {
  case campy_wx.getenv("CAMPY_ROOT") {
    "" -> cwd() <> "/../../.."
    root -> root
  }
}

fn scratch_dir() -> String {
  root() <> "/generated/apps"
}

/// Compile and load the generated module for one form: write the scratch
/// package (once), the module source, `gleam build`, and load the beam.
fn deploy(state: model.State) -> Result(campy_app.Running, String) {
  case model.active_module(state) {
    Error(error) -> Error(error)
    Ok(module) -> {
      use source <- result.try(campy_appgen.generate(
        module.slug,
        module.form,
        module.handlers,
      ))
      let dir = scratch_dir()
      let module_name = campy_appgen.module_name(module.slug)
      use _ <- result.try(make_dir(dir <> "/src"))
      use _ <- result.try(write_file(
        dir <> "/src/" <> module_name <> ".gleam",
        source,
      ))
      use _ <- result.try(write_scratch_package(dir))
      use _ <- result.try(compile_and_load(dir, module_name))

      let reply = process.new_subject()
      case campy_app.start(deploy_spec(module, module_name), reply) {
        // The subject returned by start is the actor's own mailbox; it is the
        // dispatch channel for events and StopRequest.
        Ok(subject) ->
          Ok(campy_app.Running(
            name: module.slug,
            slug: module.slug,
            module: module_name,
            version: 1,
            node: "",
            dispatch: subject,
            reply: reply,
          ))
        Error(error) -> Error(error)
      }
    }
  }
}

fn deploy_spec(module: campy_project.Module, module_name: String) {
  campy_app.Spec(
    name: module.slug,
    module: module_name,
    document: module.form,
    state_version: 1,
    migrate: None,
  )
}

fn write_scratch_package(dir: String) -> Result(Nil, String) {
  use _ <- result.try(make_dir(dir <> "/src"))
  write_file(
    dir <> "/gleam.toml",
    "name = \"campy_apps\"\n"
      <> "version = \"0.1.0\"\n"
      <> "target = \"erlang\"\n"
      <> "gleam = \">= 1.16.0 and < 2.0.0\"\n"
      <> "\n"
      <> "[dependencies]\n"
      <> "gleam_stdlib = \">= 0.70.0 and < 1.0.0\"\n"
      <> "campy_view = { path = \""
      <> root()
      <> "/gleam/packages/campy_view\" }\n"
      <> "campy_app = { path = \""
      <> root()
      <> "/gleam/packages/campy_app\" }\n",
  )
}

/// Dump the attached app's state: SnapshotRequest round trip, the state term
/// formatted into the console.
fn dump_state(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = case state.running {
    None -> model.update(state, model.Log("Nothing running"))
    Some(running) -> {
      let me = process.new_subject()
      process.send(running.dispatch, campy_app.SnapshotRequest(me))
      case process.receive(me, 2000) {
        Ok(campy_app.Snapshot(snapshot, version)) -> {
          io.println("[app] state: " <> format_term(snapshot))
          model.update(
            state,
            model.RunReport(
              "state version "
              <> int.to_string(version)
              <> ": "
              <> format_term(snapshot),
            ),
          )
        }
        Error(_) -> model.update(state, model.Log("state request timed out"))
      }
    }
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  loop(shell, state, next, dir, NoDrag)
}

/// Toggle send/receive tracing on the attached app's actor. Trace lines come
/// back as campy_wx.Message({trace_log, ...}) and land in the console.
fn toggle_trace(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = case state.running, state.tracer {
    Some(running), Some(tracer) -> {
      stop_tracer(running.node, tracer)
      model.update(state, model.TracingStopped)
    }
    Some(running), None -> {
      let assert Ok(actor) = process.subject_owner(running.dispatch)
      let tracer =
        spawn_tracer(
          running.node,
          process.self(),
          running.slug <> "@" <> running.node,
        )
      case trace_send_receive(running.node, actor, tracer, True) {
        Ok(_) -> model.update(state, model.TracingStarted(tracer))
        Error(reason) ->
          model.update(state, model.Log("trace failed: " <> reason))
      }
    }
    None, _ -> model.update(state, model.Log("Nothing running"))
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  loop(shell, state, next, dir, NoDrag)
}

/// Re-read the process list of the app's node.
fn refresh_processes(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let next = view(state)
  let shell = rebind(shell, current, next)
  set_debug(shell, state)
  loop(shell, state, next, dir, NoDrag)
}

/// Start a peer node named after the Nodes page field.
fn start_peer(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = model.update(state, model.ShowNodes)
  let state = case campy_peer.start_distribution("campy_ide") {
    Error(reason) ->
      model.update(state, model.Log("distribution failed: " <> reason))
    Ok(Nil) ->
      case campy_peer.start(state.nodes_name) {
        Ok(peer) -> model.update(state, model.PeerStarted(peer))
        Error(reason) ->
          model.update(
            state,
            model.Log("peer " <> state.nodes_name <> " failed: " <> reason),
          )
      }
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  loop(shell, state, next, dir, NoDrag)
}

/// Stop the selected peer. Anything attached to it detaches (PeerStopped).
fn stop_peer(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = case model.selected_peer(state) {
    Ok(peer) -> {
      campy_peer.stop(peer)
      model.update(state, model.PeerStopped(peer.node))
    }
    Error(error) -> model.update(state, model.Log(error))
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  loop(shell, state, next, dir, NoDrag)
}

/// Deploy the active form to the selected peer: generate, build locally,
/// push the runtime + app beams, and start the actor on the peer. The Run
/// page attaches to the peer app exactly like the in-VM one.
fn deploy_to_peer(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = case model.active_module(state) {
    Error(error) -> model.update(state, model.Log("Deploy failed: " <> error))
    Ok(module) ->
      case model.selected_peer(state) {
        Error(error) ->
          model.update(state, model.Log("Deploy failed: " <> error))
        Ok(peer) -> deploy_module_to_peer(state, module, peer)
      }
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  campy_wx.select_page(shell, "tabs", page_index(state))
  loop(shell, state, next, dir, NoDrag)
}

fn deploy_module_to_peer(
  state: model.State,
  module: campy_project.Module,
  peer: campy_peer.Peer,
) -> model.State {
  case campy_appgen.generate(module.slug, module.form, module.handlers) {
    Error(error) -> model.update(state, model.Log("Deploy failed: " <> error))
    Ok(source) -> {
      let dir = scratch_dir()
      let module_name = campy_appgen.module_name(module.slug)
      let _ = make_dir(dir <> "/src")
      let built =
        write_file(dir <> "/src/" <> module_name <> ".gleam", source)
        |> result.try(fn(_) { write_scratch_package(dir) })
        |> result.try(fn(_) { compile_and_load(dir, module_name) })
        |> result.try(fn(_) {
          // Runtime beams for a fresh peer; idempotent for a warm one.
          campy_peer.deploy_dirs(peer.node, runtime_dirs())
        })
        |> result.try(fn(_) { campy_peer.deploy_dir(peer.node, apps_dir()) })
      case built {
        Error(error) ->
          model.update(state, model.Log("Deploy failed: " <> error))
        Ok(_) -> {
          let reply = process.new_subject()
          case
            start_app_on(peer.node, deploy_spec(module, module_name), reply)
          {
            Ok(subject) -> {
              io.println(
                "[ide] deployed " <> module.slug <> " to " <> peer.node,
              )
              model.update(
                state,
                model.RunStarted(campy_app.Running(
                  name: module.slug,
                  slug: module.slug,
                  module: module_name,
                  version: 1,
                  node: peer.node,
                  dispatch: subject,
                  reply: reply,
                )),
              )
            }
            Error(error) -> {
              io.println(
                "[ide] deploy to " <> peer.node <> " failed: " <> error,
              )
              model.update(state, model.Log("Deploy failed: " <> error))
            }
          }
        }
      }
    }
  }
}

/// Redeploy (hot-upgrade) the app attached to a peer: rebuild, load the new
/// beam on the peer, pause/resume the actor around the load, then Upgrade.
fn redeploy_on_peer(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  let previous = state
  let state = model.update(state, model.ShowNodes)
  let state = case state.running {
    Some(running) if running.node != "" -> upgrade_on_peer(state, running)
    Some(_) -> model.update(state, model.Log("Nothing deployed to a peer"))
    None -> model.update(state, model.Log("Nothing running"))
  }
  let next = view(state)
  let shell = rebind(shell, current, next)
  refresh(shell, Some(previous), state)
  loop(shell, state, next, dir, NoDrag)
}

fn upgrade_on_peer(
  state: model.State,
  running: campy_app.Running,
) -> model.State {
  let next_version = running.version + 1
  let beam = apps_dir() <> "/" <> running.module <> ".beam"
  case model.active_module(state) {
    Error(error) -> model.update(state, model.Log("Redeploy failed: " <> error))
    Ok(module) ->
      case campy_appgen.generate(module.slug, module.form, module.handlers) {
        Error(error) ->
          model.update(state, model.Log("Redeploy failed: " <> error))
        Ok(source) -> {
          let dir = scratch_dir()
          let written =
            write_file(dir <> "/src/" <> running.module <> ".gleam", source)
          case written {
            Error(error) ->
              model.update(state, model.Log("Redeploy failed: " <> error))
            Ok(_) -> {
              let _ = compile_and_load(dir, running.module)
              case load_code_on(running.node, running.module, beam) {
                Ok(_) -> {
                  // The owner pid: pause/resume go through sys on the peer.
                  let assert Ok(owner) = process.subject_owner(running.dispatch)
                  let _ = pause_on(running.node, owner)
                  let state =
                    model.update(state, model.RunCodeUpdated(next_version))
                  let updated = case state.running {
                    Some(now) -> now
                    None -> running
                  }
                  let _ = resume_on(running.node, owner)
                  process.send(
                    updated.dispatch,
                    campy_app.Upgrade(
                      running.module,
                      running.version,
                      next_version,
                    ),
                  )
                  io.println(
                    "[ide] redeployed "
                    <> running.slug
                    <> " on "
                    <> running.node
                    <> " to version "
                    <> int.to_string(next_version),
                  )
                  state
                }
                Error(error) ->
                  model.update(state, model.Log("Redeploy failed: " <> error))
              }
            }
          }
        }
      }
  }
}

/// Start or stop the running app for the active module.
fn toggle_run(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
) {
  case state.running {
    Some(running) -> {
      io.println("[ide] stopping " <> running.slug)
      process.send(running.dispatch, campy_app.StopRequest)
      loop(shell, state, current, dir, NoDrag)
    }
    None ->
      case deploy(state) {
        Error(error) -> {
          io.println("[ide] run failed: " <> error)
          let previous = state
          let state = model.update(state, model.Log("Run failed: " <> error))
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
        Ok(running) -> {
          io.println("[ide] running " <> running.slug)
          let previous = state
          let state = model.update(state, model.RunStarted(running))
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          campy_wx.select_page(shell, "tabs", page_index(state))
          loop(shell, state, next, dir, NoDrag)
        }
      }
  }
}

fn help_text() -> String {
  "Ctrl+S            Save\n"
  <> "Ctrl+Q            Quit\n"
  <> "Ctrl+Z            Undo\n"
  <> "Ctrl+Shift+Z/Y    Redo\n"
  <> "Ctrl+X/C/V        Cut, copy, paste (Form page)\n"
  <> "Ctrl+D            Duplicate (Form page)\n"
  <> "Delete            Delete selection (Form page)\n"
  <> "Escape            Cancel placement or drag\n"
  <> "Ctrl+1/2/3        Form, Code, Source\n\n"
  <> "Design: click a palette button, then click or drag on the canvas.\n"
  <> "Drag a control's body to move it; drag the small blue handles to resize."
}

fn begin_body_move(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  x: Int,
  y: Int,
) {
  case selection_items(state) {
    [] -> loop(shell, state, current, dir, NoDrag)
    items -> {
      // Freeze the canvas background and cache parent origins once: motion
      // must not resolve the document or repaint the grid on every event.
      campy_wx.freeze_canvas(shell)
      loop(
        shell,
        state,
        current,
        dir,
        MoveDrag(items, x, y, True, #(x, y), drag_origins(state, items)),
      )
    }
  }
}

fn drag_origins(
  state: model.State,
  items: List(#(String, #(Int, Int, Int, Int))),
) -> dict.Dict(String, #(Int, Int)) {
  case model.active_module(state) {
    Error(_) -> dict.new()
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      list.fold(items, dict.new(), fn(acc, item) {
        let #(id, _) = item
        let #(ox, oy) = campy_design.parent_origin_in(layout, id)
        dict.insert(acc, id, #(ox, oy))
      })
    }
  }
}

/// The drag engine. All gesture events arrive on the canvas after it captured
/// the pointer, so coordinates are canvas-relative and no separate chrome
/// widgets are needed for interaction.
fn handle_mouse(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  kind: String,
  x: Int,
  y: Int,
) {
  case kind {
    "motion" -> {
      let drag = drag_at(drag, x, y)
      let #(px, py) = drag_point(drag, x, y)
      let origins = drag_origins_of(drag)
      let previews = drag_previews(drag, px, py)
      list.each(previews, fn(preview) {
        let #(id, rect) = preview
        let #(rx, ry, rw, rh) = preview_in_parent_cached(origins, id, rect)
        campy_wx.preview_rect(shell, id, rx, ry, rw, rh)
      })
      // A body drag needs no canvas capture (GTK's implicit grab keeps sending
      // motion to the pressed control), so moving the outline cannot shift the
      // coordinate base. A grip drag captures the grip itself and must keep
      // its chrome still (invariant 6).
      loop(shell, state, current, dir, drag)
    }
    "left_up" -> {
      campy_wx.release_canvas(shell)
      campy_wx.thaw_canvas(shell)
      let #(px, py) = drag_point(drag, x, y)
      // GTK/Wx can report the press coordinates in the release event for a
      // native child. The last motion event is the authoritative end point.
      case drag_previews(drag, px, py) {
        [] -> loop(shell, state, current, dir, NoDrag)
        previews -> {
          let previous = state
          let reparent = move_reparent(state, drag, previews)
          let state =
            model.update(
              state,
              model.CommitGeometry(
                list.map(previews, fn(preview) {
                  let #(id, #(rx, ry, rw, rh)) = preview
                  #(id, campy_design.Rect(x: rx, y: ry, w: rw, h: rh))
                }),
                reparent,
              ),
            )
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          campy_wx.release_canvas(shell)
          loop(shell, state, next, dir, NoDrag)
        }
      }
    }
    _ -> loop(shell, state, current, dir, drag)
  }
}

fn handle_design_mouse(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  drag: Drag,
  id: String,
  kind: String,
  x: Int,
  y: Int,
  control: Bool,
) {
  // Every gesture coordinate is canvas space from here on.
  let #(ax, ay) = event_absolute(state, id, x, y)
  case kind {
    "left_down" -> {
      case state.armed {
        Some(kind) ->
          start_placement(shell, state, current, dir, kind, id, x, y)
        None ->
          // Hit-tested handles come first: a press inside one of the selected
          // control's handle zones starts a resize.
          case handle_hit(state, ax, ay) {
            Some(role) -> begin_resize(shell, state, current, dir, role, ax, ay)
            None ->
              case id {
                "canvas" ->
                  case hit_target(state, x, y) {
                    Some(target) ->
                      case control {
                        True -> {
                          let previous = state
                          let state = toggle_selection(state, target)
                          let next = view(state)
                          let shell = rebind(shell, current, next)
                          refresh(shell, Some(previous), state)
                          campy_wx.focus(shell, "canvas")
                          loop(shell, state, next, dir, NoDrag)
                        }
                        False -> {
                          let previous = state
                          let state = case
                            list.contains(state.selection, target)
                          {
                            True -> state
                            False -> model.select_controls(state, [target])
                          }
                          let next = view(state)
                          let shell = rebind(shell, current, next)
                          refresh(shell, Some(previous), state)
                          campy_wx.focus(shell, "canvas")
                          begin_body_move(shell, state, next, dir, ax, ay)
                        }
                      }
                    None -> {
                      let state = model.select_controls(state, [])
                      campy_wx.show_selection(shell, None, False)
                      campy_wx.capture_canvas(shell)
                      let previous = state
                      refresh(shell, Some(previous), state)
                      loop(shell, state, current, dir, MarqueeDrag(ax, ay))
                    }
                  }
                _ -> {
                  let previous = state
                  let state = case control {
                    True -> toggle_widget_selection(state, id)
                    False ->
                      case list.contains(state.selection, id) {
                        True -> state
                        False -> select_control(state, id, "select")
                      }
                  }
                  let next = view(state)
                  let shell = rebind(shell, current, next)
                  refresh(shell, Some(previous), state)
                  campy_wx.focus(shell, "canvas")
                  begin_body_move(shell, state, next, dir, ax, ay)
                }
              }
          }
      }
    }
    "motion" ->
      case drag {
        NoDrag ->
          case model.active_module(state) {
            Ok(_module) -> {
              // Hover feedback for the hit-tested handles.
              let role = case list.length(state.selection) {
                1 -> handle_role_of_selection(state, ax, ay)
                _ -> None
              }
              campy_wx.set_canvas_cursor(shell, case role {
                Some(value) -> value
                None -> 99
              })
              loop(shell, state, current, dir, drag)
            }
            Error(_) -> loop(shell, state, current, dir, drag)
          }
        PlacementDrag(_kind, start_x, start_y) -> {
          campy_wx.show_marquee(
            shell,
            Some(normalize_rect(start_x, start_y, ax, ay)),
          )
          loop(shell, state, current, dir, drag)
        }
        MarqueeDrag(start_x, start_y) -> {
          campy_wx.show_marquee(
            shell,
            Some(normalize_rect(start_x, start_y, ax, ay)),
          )
          loop(shell, state, current, dir, drag)
        }
        MoveDrag(_, _, _, _, _, _) ->
          handle_mouse(shell, state, current, dir, drag, kind, ax, ay)
        ResizeDrag(_, _, _, _, _, _, _) ->
          handle_mouse(shell, state, current, dir, drag, kind, ax, ay)
      }
    "left_up" ->
      case drag {
        MoveDrag(_, _, _, _, _, _) ->
          handle_mouse(shell, state, current, dir, drag, kind, ax, ay)
        ResizeDrag(_, _, _, _, _, _, _) -> {
          campy_wx.set_canvas_cursor(shell, 99)
          handle_mouse(shell, state, current, dir, drag, kind, ax, ay)
        }
        PlacementDrag(kind, start_x, start_y) -> {
          let rect = normalize_rect(start_x, start_y, ax, ay)
          campy_wx.release_canvas(shell)
          campy_wx.show_marquee(shell, None)
          let previous = state
          let #(width, height) = case rect.2 < 6 || rect.3 < 6 {
            True -> #(0, 0)
            False -> #(rect.2, rect.3)
          }
          let state =
            model.update(
              state,
              model.PlaceWidget(kind, rect.0, rect.1, width, height),
            )
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
        NoDrag -> loop(shell, state, current, dir, drag)
        MarqueeDrag(start_x, start_y) -> {
          let rect = normalize_rect(start_x, start_y, ax, ay)
          campy_wx.release_canvas(shell)
          campy_wx.show_marquee(shell, None)
          let state = case model.active_module(state) {
            Error(_) -> state
            Ok(module) -> {
              let layout = campy_design.resolve(module.form.view)
              model.select_controls(
                state,
                campy_design.intersecting(
                  layout,
                  campy_design.Rect(x: rect.0, y: rect.1, w: rect.2, h: rect.3),
                ),
              )
            }
          }
          let previous = state
          let next = view(state)
          let shell = rebind(shell, current, next)
          refresh(shell, Some(previous), state)
          loop(shell, state, next, dir, NoDrag)
        }
      }
    _ -> loop(shell, state, current, dir, drag)
  }
}

fn normalize_rect(sx: Int, sy: Int, x: Int, y: Int) -> #(Int, Int, Int, Int) {
  #(
    int.min(sx, x),
    int.min(sy, y),
    int.max(sx, x) - int.min(sx, x) + 1,
    int.max(sy, y) - int.min(sy, y) + 1,
  )
}

fn hit_target(state: model.State, x: Int, y: Int) -> Option(String) {
  case model.active_module(state) {
    Error(_) -> None
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      case campy_design.at(layout, x, y) {
        Some(placed) ->
          case placed.id == layout.root {
            True -> None
            False -> Some(placed.id)
          }
        None -> None
      }
    }
  }
}

fn start_placement(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  kind: String,
  id: String,
  x: Int,
  y: Int,
) {
  case id {
    "canvas" -> {
      campy_wx.capture_canvas(shell)
      loop(shell, state, current, dir, PlacementDrag(kind, x, y))
    }
    _ -> {
      let #(px, py) = event_absolute(state, id, x, y)
      let previous = state
      let state = model.update(state, model.PlaceWidget(kind, px, py, 0, 0))
      let next = view(state)
      let shell = rebind(shell, current, next)
      refresh(shell, Some(previous), state)
      loop(shell, state, next, dir, NoDrag)
    }
  }
}

/// Convert a click on any design widget into canvas coordinates. Labels often
/// do not emit mouse events on GTK, but buttons, panels, and text fields do.
fn event_absolute(
  state: model.State,
  id: String,
  x: Int,
  y: Int,
) -> #(Int, Int) {
  case id {
    "canvas" -> #(x, y)
    _ ->
      case model.active_module(state) {
        Error(_) -> #(x, y)
        Ok(module) ->
          case campy_design.absolute(module.form.view, id) {
            Some(rect) -> #(rect.x + x, rect.y + y)
            None -> #(x, y)
          }
      }
  }
}

/// A single-control move that ends over another container reparents it. Group
/// moves stay together in their current parent.
fn move_reparent(
  state: model.State,
  drag: Drag,
  previews: List(#(String, #(Int, Int, Int, Int))),
) -> Option(#(String, String)) {
  case drag {
    MoveDrag([#(id, original)], _, _, _, _, _) ->
      case list.find(previews, fn(preview) { preview.0 == id }) {
        Error(Nil) -> None
        Ok(#(_, preview)) ->
          // A click on the grip without movement must not reparent or freeze,
          // even if the control's center happens to sit over a container.
          case preview == original {
            True -> None
            False -> {
              let #(x, y, w, h) = preview
              case model.active_module(state) {
                Error(_) -> None
                Ok(module) -> {
                  let layout = campy_design.resolve(module.form.view)
                  let current = campy_design.parent_of(module.form.view, id)
                  let target =
                    campy_design.container_for_drop(
                      module.form.view,
                      layout,
                      x + w / 2,
                      y + h / 2,
                      Some(id),
                    )
                  case target {
                    None -> None
                    Some(placed) ->
                      case current {
                        Some(parent) if parent == placed.id -> None
                        _ -> Some(#(id, placed.id))
                      }
                  }
                }
              }
            }
          }
      }
    _ -> None
  }
}

fn selection_items(
  state: model.State,
) -> List(#(String, #(Int, Int, Int, Int))) {
  case model.active_module(state) {
    Error(_) -> []
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      // Moving a container already moves its descendants; preview and commit
      // only the top-level selected controls.
      let ids =
        list.filter(state.selection, fn(id) {
          !list.any(state.selection, fn(other) {
            other != id && campy_design.is_within(module.form.view, other, id)
          })
        })
      list.filter_map(ids, fn(id) {
        case campy_design.placed(layout, id) {
          Some(placed) ->
            Ok(#(
              id,
              #(placed.rect.x, placed.rect.y, placed.rect.w, placed.rect.h),
            ))
          None -> Error(Nil)
        }
      })
    }
  }
}

/// A resize gesture starts on a hit-tested handle zone. The control's
/// absolute rectangle and its parent origin are captured once.
fn start_resize(state: model.State, role: Int, x: Int, y: Int) -> Drag {
  case state.selection {
    [id] ->
      case selection_items(state) {
        [#(_, rect), ..] ->
          ResizeDrag(
            id,
            role,
            x,
            y,
            rect,
            #(x, y),
            drag_origins(state, selection_items(state)),
          )
        [] -> NoDrag
      }
    _ -> NoDrag
  }
}

fn begin_resize(
  shell: campy_wx.Shell,
  state: model.State,
  current: Node,
  dir: String,
  role: Int,
  x: Int,
  y: Int,
) {
  // The press landed on the control body, so GTK's implicit grab delivers the
  // matching motion and release to the same widget. Capturing the canvas from
  // inside a child press loses the release on GTK.
  campy_wx.freeze_canvas(shell)
  loop(shell, state, current, dir, start_resize(state, role, x, y))
}

/// Which handle role is under the point, in canvas coordinates. Corners win
/// over edges; the tolerance matches the 9 px handle size.
pub fn handle_role_at(
  rect: #(Int, Int, Int, Int),
  x: Int,
  y: Int,
) -> Option(Int) {
  let #(rx, ry, rw, rh) = rect
  let near = fn(value: Int, target: Int) {
    value >= target - 6 && value <= target + 6
  }
  let left = near(x, rx)
  let right = near(x, rx + rw)
  let top = near(y, ry)
  let bottom = near(y, ry + rh)
  let on_x = x >= rx && x <= rx + rw
  let on_y = y >= ry && y <= ry + rh

  case left && top {
    True -> Some(0)
    False ->
      case right && top {
        True -> Some(2)
        False ->
          case right && bottom {
            True -> Some(4)
            False ->
              case left && bottom {
                True -> Some(6)
                False ->
                  case top && on_x {
                    True -> Some(1)
                    False ->
                      case right && on_y {
                        True -> Some(3)
                        False ->
                          case bottom && on_x {
                            True -> Some(5)
                            False ->
                              case left && on_y {
                                True -> Some(7)
                                False -> None
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

fn handle_hit(state: model.State, ax: Int, ay: Int) -> Option(Int) {
  case list.length(state.selection) {
    1 -> handle_role_of_selection(state, ax, ay)
    _ -> None
  }
}

fn handle_role_of_selection(
  state: model.State,
  ax: Int,
  ay: Int,
) -> Option(Int) {
  case selection_items(state) {
    [#(_, rect), ..] -> handle_role_at(rect, ax, ay)
    [] -> None
  }
}

fn drag_at(drag: Drag, x: Int, y: Int) -> Drag {
  case drag {
    MoveDrag(items, start_x, start_y, follow, _, origins) ->
      MoveDrag(items, start_x, start_y, follow, #(x, y), origins)
    ResizeDrag(id, role, start_x, start_y, rect, _, origins) ->
      ResizeDrag(id, role, start_x, start_y, rect, #(x, y), origins)
    _ -> drag
  }
}

/// Parent origins cached at drag start. Motion events must not resolve the
/// document: they only add a delta to the captured rectangles.
fn drag_origins_of(drag: Drag) -> dict.Dict(String, #(Int, Int)) {
  case drag {
    MoveDrag(_, _, _, _, _, origins) -> origins
    ResizeDrag(_, _, _, _, _, _, origins) -> origins
    _ -> dict.new()
  }
}

fn preview_in_parent_cached(
  origins: dict.Dict(String, #(Int, Int)),
  id: String,
  rect: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int) {
  case dict.get(origins, id) {
    Ok(#(ox, oy)) -> {
      let #(x, y, w, h) = rect
      #(x - ox, y - oy, w, h)
    }
    // Never reached for a body drag: every MoveDrag item gets an origin at
    // gesture start. If a handle path reaches here, treat the rect as canvas
    // coordinates (its origin is 0).
    Error(_) -> rect
  }
}

fn drag_point(drag: Drag, fallback_x: Int, fallback_y: Int) -> #(Int, Int) {
  case drag {
    MoveDrag(_, _, _, _, #(x, y), _) -> #(x, y)
    ResizeDrag(_, _, _, _, _, point, _) -> point
    _ -> #(fallback_x, fallback_y)
  }
}

fn drag_previews(
  drag: Drag,
  x: Int,
  y: Int,
) -> List(#(String, #(Int, Int, Int, Int))) {
  case drag {
    NoDrag -> []
    PlacementDrag(_, _, _) -> []
    MarqueeDrag(_, _) -> []
    MoveDrag(items, start_x, start_y, _follow, _current, _) ->
      list.map(items, fn(item) {
        let #(id, #(rx, ry, rw, rh)) = item
        #(id, #(rx + x - start_x, ry + y - start_y, rw, rh))
      })
    ResizeDrag(
      id,
      role,
      start_x,
      start_y,
      #(rx, ry, rw, rh),
      _current,
      _origins,
    ) -> {
      let dx = x - start_x
      let dy = y - start_y
      let left = case role {
        0 | 6 | 7 -> rx + dx
        _ -> rx
      }
      let top = case role {
        0 | 1 | 2 -> ry + dy
        _ -> ry
      }
      let right = case role {
        2 | 3 | 4 -> rx + rw + dx
        _ -> rx + rw
      }
      let bottom = case role {
        4 | 5 | 6 -> ry + rh + dy
        _ -> ry + rh
      }
      let #(left, right) = case right - left < campy_design.min_size {
        True ->
          case role {
            0 | 6 | 7 -> #(right - campy_design.min_size, right)
            _ -> #(left, left + campy_design.min_size)
          }
        False -> #(left, right)
      }
      let #(top, bottom) = case bottom - top < campy_design.min_size {
        True ->
          case role {
            0 | 1 | 2 -> #(bottom - campy_design.min_size, bottom)
            _ -> #(top, top + campy_design.min_size)
          }
        False -> #(top, bottom)
      }
      [#(id, #(left, top, right - left, bottom - top))]
    }
  }
}

type Drag {
  NoDrag
  PlacementDrag(kind: String, start_x: Int, start_y: Int)
  MarqueeDrag(start_x: Int, start_y: Int)
  MoveDrag(
    items: List(#(String, #(Int, Int, Int, Int))),
    start_x: Int,
    start_y: Int,
    follow: Bool,
    current: #(Int, Int),
    origins: dict.Dict(String, #(Int, Int)),
  )
  ResizeDrag(
    id: String,
    role: Int,
    start_x: Int,
    start_y: Int,
    rect: #(Int, Int, Int, Int),
    current: #(Int, Int),
    origins: dict.Dict(String, #(Int, Int)),
  )
}

fn handle(
  state: model.State,
  dir: String,
  id: String,
  key: String,
  value: campy_view.Value,
) -> model.State {
  case id {
    "menu-save" | "tool-save" -> save(state, dir)
    "menu-undo" | "tool-undo" -> model.update(state, model.Undo)
    "menu-redo" | "tool-redo" -> model.update(state, model.Redo)
    "menu-form" -> model.update(state, model.ShowForm)
    "menu-code" -> model.update(state, model.ShowCode)
    "menu-source" -> model.update(state, model.ShowSource)
    "menu-copy" | "tool-copy" -> model.update(state, model.CopySelection)
    "menu-cut" | "tool-cut" -> model.update(state, model.CutSelection)
    "menu-paste" | "tool-paste" -> model.update(state, model.Paste)
    "menu-duplicate" | "tool-duplicate" ->
      model.update(state, model.DuplicateSelection)
    "menu-delete" | "tool-delete" | "inspector-delete" ->
      model.update(state, model.DeleteSelection)
    "menu-front" -> model.update(state, model.BringToFront)
    "menu-back" -> model.update(state, model.SendToBack)
    "menu-cancel-place" -> model.update(state, model.Disarm)
    "console-clear" -> model.update(state, model.ClearConsole)
    "tabs" -> page_selected(state, value)
    "inspector-tabs" -> state
    "inspector" -> inspector_changed(state, value)
    "events" -> event_selected(state, value)
    "modules" -> module_selected(state, value)
    "nodes-name" ->
      case value {
        campy_view.VText(name) -> model.update(state, model.SetNodesName(name))
        _ -> state
      }
    "nodes-list" ->
      case value {
        campy_view.VInt(index) ->
          case list.drop(model.peer_nodes(state), index) {
            [node, ..] -> model.update(state, model.PeerSelected(node))
            [] -> state
          }
        _ -> state
      }
    _ -> {
      let kind = string.drop_start(id, string.length("palette-"))
      case string.starts_with(id, "palette-") {
        True -> model.update(state, model.Arm(kind))
        False ->
          case route_live_event(state, id, key, value) {
            True -> state
            False -> select_or_log(state, id, key)
          }
      }
    }
  }
}

fn page_selected(state: model.State, value: campy_view.Value) -> model.State {
  case value {
    VInt(1) -> model.update(state, model.ShowCode)
    VInt(2) -> model.update(state, model.ShowSource)
    VInt(4) -> model.update(state, model.ShowNodes)
    VInt(5) -> model.update(state, model.ShowDebug)
    VInt(_) -> model.update(state, model.ShowTabs)
    _ -> state
  }
}

fn module_selected(state: model.State, value: campy_view.Value) -> model.State {
  case value {
    VInt(index) if index >= 0 ->
      case list.drop(module_items(state), index) {
        [slug, ..] -> tree_selected(state, slug)
        [] -> state
      }
    _ -> state
  }
}

/// A grid edit arrives as row/col/text. Columns 0 is the field label and 1 is
/// its value; the field comes from the label in the same row, never a hard-coded
/// row index, so single and multi-selection layouts can differ.
fn inspector_changed(
  state: model.State,
  value: campy_view.Value,
) -> model.State {
  case value {
    VMap(fields) ->
      case
        field_int(fields, "row"),
        field_int(fields, "col"),
        field_text(fields, "text")
      {
        Some(row), Some(col), Some(text) ->
          case col {
            1 ->
              case list.drop(inspector_rows(state), row) {
                [row_values, ..] ->
                  case row_values {
                    [label, _] -> inspector_edit(state, label, text)
                    _ -> state
                  }
                [] -> state
              }
            _ -> state
          }
        _, _, _ -> state
      }
    _ -> state
  }
}

fn field_int(
  fields: List(#(String, campy_view.Value)),
  name: String,
) -> Option(Int) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, VInt(value))) -> Some(value)
    _ -> None
  }
}

fn field_text(
  fields: List(#(String, campy_view.Value)),
  name: String,
) -> Option(String) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, VText(value))) -> Some(value)
    _ -> None
  }
}

fn inspector_edit(
  state: model.State,
  label: String,
  text: String,
) -> model.State {
  case state.selection {
    [id] ->
      case label {
        "x" | "y" | "w" | "h" -> edit_geometry(state, id, label, text)
        "text" ->
          model.update(state, model.SetControlProp(id, "text", VText(text)))
        "title" ->
          model.update(state, model.SetControlProp(id, "title", VText(text)))
        _ -> state
      }
    [] ->
      case model.active_module(state) {
        Ok(module) ->
          case label {
            "w" | "h" ->
              edit_root_dimension(state, module.form.view.id, label, text)
            "title" ->
              model.update(
                state,
                model.SetControlProp(module.form.view.id, "title", VText(text)),
              )
            _ -> state
          }
        Error(_) -> state
      }
    _ -> state
  }
}

fn edit_geometry(
  state: model.State,
  id: String,
  field: String,
  text: String,
) -> model.State {
  case int.parse(string.trim(text)), geometry_of(state, id) {
    Ok(value), Some(rect) -> {
      let next = case field {
        "x" -> campy_design.Rect(x: value, y: rect.y, w: rect.w, h: rect.h)
        "y" -> campy_design.Rect(x: rect.x, y: value, w: rect.w, h: rect.h)
        "w" -> campy_design.Rect(x: rect.x, y: rect.y, w: value, h: rect.h)
        _ -> campy_design.Rect(x: rect.x, y: rect.y, w: rect.w, h: value)
      }
      model.update(state, model.SetControlRect(id, next))
    }
    _, _ -> state
  }
}

/// The window is the layout root: changing its width/height must not freeze a
/// column/row form. Set the root property directly instead of going through
/// `SetControlRect`.
fn edit_root_dimension(
  state: model.State,
  root_id: String,
  field: String,
  text: String,
) -> model.State {
  case int.parse(string.trim(text)) {
    Ok(value) ->
      model.update(
        state,
        model.SetControlProp(
          root_id,
          field,
          VInt(int.max(value, campy_design.min_size)),
        ),
      )
    Error(_) -> state
  }
}

fn geometry_of(state: model.State, id: String) -> Option(campy_design.Rect) {
  case model.active_module(state) {
    Ok(module) -> campy_design.absolute(module.form.view, id)
    Error(_) -> None
  }
}

fn event_selected(state: model.State, value: campy_view.Value) -> model.State {
  case value, state.selection {
    VInt(index), [id] ->
      case list.drop(event_items(state), index) {
        [event, ..] -> model.update(state, model.OpenHandler(id, event))
        [] -> state
      }
    _, _ -> state
  }
}

pub fn events_display(state: model.State) -> List(String) {
  event_items(state)
}

fn select_or_log(state: model.State, id: String, key: String) -> model.State {
  case id {
    "canvas" -> state
    _ -> select_control(state, id, key)
  }
}

fn toggle_widget_selection(state: model.State, id: String) -> model.State {
  case model.active_module(state) {
    Error(_) -> state
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        Some(_) -> toggle_selection(state, id)
        None -> state
      }
  }
}

fn select_control(state: model.State, id: String, key: String) -> model.State {
  case model.active_module(state) {
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        Some(_node) -> model.select_controls(state, [id])
        None -> model.update(state, model.Log("event " <> id <> "." <> key))
      }
    Error(_) -> model.update(state, model.Log("event " <> id <> "." <> key))
  }
}

/// Canvas clicks are hit-tested, not trusted to per-control events: GTK labels
/// do not emit mouse events, and bubbled clicks can otherwise clear a fresh
/// selection.
fn toggle_selection(state: model.State, id: String) -> model.State {
  case list.contains(state.selection, id) {
    True ->
      model.select_controls(
        state,
        list.filter(state.selection, fn(selected) { selected != id }),
      )
    False -> model.select_controls(state, list.append(state.selection, [id]))
  }
}

fn tree_selected(state: model.State, id: String) -> model.State {
  case campy_project.module(state.project, id) {
    Ok(_module) -> model.update(state, model.OpenModule(id))
    Error(_) -> state
  }
}

fn save(state: model.State, dir: String) -> model.State {
  let state = case campy_project.save(state.project, dir) {
    Ok(Nil) -> model.update(state, model.Log("Saved " <> dir))
    Error(error) -> model.update(state, model.Log("Save failed: " <> error))
  }
  // A running app picks the new handlers up immediately (T3.4 code update).
  case state.running {
    None -> state
    Some(running) -> update_code(state, running)
  }
}

/// Hot-update a running app: regenerate and build the module, pause the
/// actor, load the new beam in place, resume, then send Upgrade so the actor
/// runs its `migrate/2` and republishes. A failed step is a no-op that
/// leaves the running version untouched.
fn update_code(state: model.State, running: campy_app.Running) -> model.State {
  let next_version = running.version + 1
  case model.active_module(state) {
    Error(_) -> state
    Ok(module) ->
      case campy_appgen.generate(module.slug, module.form, module.handlers) {
        Error(error) ->
          model.update(state, model.Log("Update failed: " <> error))
        Ok(source) -> {
          let dir = scratch_dir()
          let module_name = campy_appgen.module_name(module.slug)
          let beam =
            dir
            <> "/build/dev/erlang/campy_apps/ebin/"
            <> module_name
            <> ".beam"
          let written =
            write_file(dir <> "/src/" <> module_name <> ".gleam", source)
          let state = case written {
            Ok(_) -> state
            Error(error) ->
              model.update(state, model.Log("Update failed: " <> error))
          }
          case written {
            Error(_) -> state
            Ok(_) -> {
              // Recompile; the load below swaps the beam in place.
              let _ = compile_and_load(dir, module_name)
              case campy_app.load_code(module_name, beam) {
                Ok(_) -> {
                  campy_app.pause(running)
                  let state =
                    model.update(state, model.RunCodeUpdated(next_version))
                  let updated = case state.running {
                    Some(now) -> now
                    None -> running
                  }
                  campy_app.resume(updated)
                  process.send(
                    updated.dispatch,
                    campy_app.Upgrade(
                      module_name,
                      running.version,
                      next_version,
                    ),
                  )
                  io.println(
                    "[ide] updated "
                    <> running.slug
                    <> " to version "
                    <> int.to_string(next_version),
                  )
                  state
                }
                Error(error) ->
                  model.update(state, model.Log("Update failed: " <> error))
              }
            }
          }
        }
      }
  }
}

fn refresh(
  shell: campy_wx.Shell,
  previous: Option(model.State),
  state: model.State,
) {
  case previous {
    None -> {
      set_code(shell, state)
      set_source(shell, state)
      set_console(shell, state)
      set_nodes(shell, state)
      set_debug(shell, state)
      campy_wx.select_page(shell, "tabs", page_index(state))
    }
    Some(previous) -> {
      // Handler edits and module changes must both refresh the Scintilla page;
      // otherwise a stub is committed but the old source stays visible.
      let handlers_changed = handlers_of(previous) != handlers_of(state)
      case previous.active == state.active && !handlers_changed {
        False -> {
          set_code(shell, state)
          case handlers_changed {
            True -> campy_wx.scroll_editor_to_end(shell, "code")
            False -> Nil
          }
        }
        True -> Nil
      }
      // Generated source depends only on the active module's document. Compare
      // the rendered text so console/status/selection events leave the editor
      // (and its scroll position) alone.
      case source_text(previous) == source_text(state) {
        False -> set_source(shell, state)
        True -> Nil
      }
      case previous.console == state.console {
        False -> set_console(shell, state)
        True -> Nil
      }
      case previous.peers == state.peers {
        False -> set_nodes(shell, state)
        True -> Nil
      }
      case previous.debug_view == state.debug_view {
        False -> set_debug(shell, state)
        True -> Nil
      }
    }
  }

  // Keep the notebook in sync with the model even when a tab click did not
  // produce a command event: a shortcut must still be able to switch pages.
  campy_wx.select_page(shell, "tabs", page_index(state))
  sync_shortcuts(shell, previous, state)
  // On the Form page, hand keyboard focus to the canvas after every refresh.
  // Design controls are not text editors; letting one keep focus makes it
  // consume Ctrl+C/V/Y before the frame accelerators see them.
  case page_index(state) {
    0 -> campy_wx.focus(shell, "canvas")
    _ -> Nil
  }

  let rows = inspector_rows(state)
  campy_wx.set_grid(shell, "inspector", rows)
  typed_grid_editors(shell, rows, list.length(state.selection) != 1)
  case page_index(state) == 0 {
    True ->
      campy_wx.show_selection(
        shell,
        selection_rect(state),
        list.length(state.selection) == 1,
      )
    False -> campy_wx.show_selection(shell, None, False)
  }
}

/// Rebuild the accelerator table only when Form/Code/Source changes; each
/// table is a native object.
fn sync_shortcuts(
  shell: campy_wx.Shell,
  previous: Option(model.State),
  state: model.State,
) {
  let editing = state.code_view || state.source_view
  case previous {
    None -> campy_wx.set_shortcuts(shell, editing)
    Some(previous) -> {
      let was_editing = previous.code_view || previous.source_view
      case was_editing == editing {
        True -> Nil
        False -> campy_wx.set_shortcuts(shell, editing)
      }
    }
  }
}

pub fn page_index(state: model.State) -> Int {
  case state.debug_view {
    True -> 5
    False ->
      case state.nodes_view {
        // The Nodes page is an explicit choice; it wins even while an app runs.
        True -> 4
        False ->
          case state.running {
            Some(_) -> 3
            None ->
              case state.source_view, state.code_view {
                True, _ -> 2
                False, True -> 1
                False, False -> 0
              }
          }
      }
  }
}

fn set_code(shell: campy_wx.Shell, state: model.State) {
  case model.active_module(state) {
    Ok(module) -> campy_wx.set_editor(shell, "code", module.handlers, False)
    Error(_) -> campy_wx.set_editor(shell, "code", "", True)
  }
}

/// Read-only construction source for the active form, regenerated from the
/// canonical document. `form.json` stays the source of truth (ADR 0005); this
/// text is derived output and is never loaded back.
pub fn source_text(state: model.State) -> String {
  case model.active_module(state) {
    Ok(module) -> campy_source.generate(module.slug, module.form)
    Error(_) -> "//// Generated by Campy. No active module.\n"
  }
}

fn set_source(shell: campy_wx.Shell, state: model.State) {
  campy_wx.set_editor(shell, "source", source_text(state), True)
}

fn handlers_of(state: model.State) -> String {
  case model.active_module(state) {
    Ok(module) -> module.handlers
    Error(_) -> ""
  }
}

/// x/y/w/h are integer cells; the rest stay text. Multi-selection is
/// read-only, so those cells reject edits instead of silently changing one of
/// several controls.
fn typed_grid_editors(
  shell: campy_wx.Shell,
  rows: List(List(String)),
  read_only: Bool,
) -> Nil {
  let _ =
    list.index_map(rows, fn(row, index) {
      case row {
        [label, _value] -> {
          // Field names are display only; only the value cell is editable.
          campy_wx.set_grid_read_only(shell, "inspector", index, 0, True)
          case label {
            "x" | "y" ->
              campy_wx.set_grid_number_cell(shell, "inspector", index, 1, 0)
            "w" | "h" ->
              campy_wx.set_grid_number_cell(
                shell,
                "inspector",
                index,
                1,
                campy_design.min_size,
              )
            _ -> campy_wx.set_grid_text_cell(shell, "inspector", index, 1)
          }
          let editable = case label {
            "x" | "y" | "w" | "h" | "text" | "title" -> True
            _ -> False
          }
          campy_wx.set_grid_read_only(
            shell,
            "inspector",
            index,
            1,
            read_only || !editable,
          )
        }
        _ -> Nil
      }
    })
  Nil
}

fn set_debug(shell: campy_wx.Shell, state: model.State) {
  let node = case state.running {
    Some(running) -> running.node
    None -> ""
  }
  case processes_on(node) {
    Ok(rows) ->
      campy_wx.set_items(
        shell,
        "debug-list",
        list.map(rows, fn(row) {
          row.0
          <> "  r"
          <> int.to_string(row.1)
          <> "  q"
          <> int.to_string(row.2)
        }),
      )
    Error(_) -> campy_wx.set_items(shell, "debug-list", [])
  }
}

fn set_nodes(shell: campy_wx.Shell, state: model.State) {
  campy_wx.set_items(shell, "nodes-list", model.peer_nodes(state))
}

fn set_console(shell: campy_wx.Shell, state: model.State) {
  campy_wx.set_editor(shell, "console", model.console_text(state), True)
  // Keep the newest lines in view.
  campy_wx.scroll_editor_to_end(shell, "console")
}

fn selection_rect(state: model.State) -> Option(#(Int, Int, Int, Int)) {
  case selection_items(state) {
    [] -> None
    [#(_, first), ..rest] ->
      Some(
        list.fold(rest, first, fn(acc, item) {
          let #(_, rect) = item
          union(acc, rect)
        }),
      )
  }
}

fn union(
  a: #(Int, Int, Int, Int),
  b: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int) {
  let #(ax, ay, aw, ah) = a
  let #(bx, by, bw, bh) = b
  let x = int.min(ax, bx)
  let y = int.min(ay, by)
  let right = int.max(ax + aw, bx + bw)
  let bottom = int.max(ay + ah, by + bh)
  #(x, y, right - x, bottom - y)
}

fn status_text(state: model.State) -> String {
  case state.status {
    "" -> model.status_line(state)
    status -> model.status_line(state) <> "  —  " <> status
  }
}

pub fn module_items(state: model.State) -> List(String) {
  list.map(state.project.modules, fn(module) { module.slug })
}

pub fn project_items(state: model.State) -> List(String) {
  [state.project.title]
}

pub fn module_index(state: model.State) -> Int {
  case state.active {
    Some(slug) -> index_of_item(module_items(state), slug)
    None -> 0
  }
}

fn index_of_item(items: List(String), item: String) -> Int {
  index_of_item_loop(items, item, 0)
}

fn index_of_item_loop(items: List(String), item: String, index: Int) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case first == item {
        True -> index
        False -> index_of_item_loop(rest, item, index + 1)
      }
  }
}

pub fn selection_title(state: model.State) -> String {
  case state.selection {
    [] ->
      case model.active_module(state) {
        Ok(module) ->
          "Window — "
          <> case campy_view.prop(module.form.view, "title") {
            Ok(VText(title)) -> title
            _ -> module.slug
          }
        Error(_) -> "No selection"
      }
    [id] ->
      case model.active_module(state) {
        Ok(module) ->
          case campy_design.find_node(module.form.view, id) {
            Some(node) ->
              case id == module.form.view.id {
                True -> "Window — " <> id
                False -> id <> " — " <> node.kind
              }
            None -> id
          }
        Error(_) -> id
      }
    ids -> int.to_string(list.length(ids)) <> " selected"
  }
}

/// Centre header: the active module and the form's resolved canvas size.
pub fn centre_header(state: model.State) -> String {
  let #(w, h) = case model.active_module(state) {
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      case campy_design.placed(layout, layout.root) {
        Some(placed) -> #(placed.rect.w, placed.rect.h)
        None -> #(600, 400)
      }
    }
    Error(_) -> #(600, 400)
  }
  active_slug(state)
  <> "    Canvas "
  <> int.to_string(w)
  <> " × "
  <> int.to_string(h)
}

pub fn inspector_rows(state: model.State) -> List(List(String)) {
  case state.selection {
    [] -> summary_rows(state)
    [id] -> control_rows(state, id)
    ids -> multi_rows(state, ids)
  }
}

/// Event keys for the events list beside the inspector. Only a single selected
/// control contributes; the list stays empty for multi-selection.
pub fn event_items(state: model.State) -> List(String) {
  model.selected_events(state)
}

/// Multi-selection shows only properties every selected control shares; a
/// differing value is blank. Geometry stays absolute (invariant 8), so nested
/// controls compare their canvas rectangles, not parent-relative props.
fn multi_rows(state: model.State, ids: List(String)) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> summary_rows(state)
    Ok(module) -> {
      let nodes =
        list.filter_map(ids, fn(id) {
          case campy_design.find_node(module.form.view, id) {
            Some(node) -> Ok(node)
            None -> Error(Nil)
          }
        })
      let rects =
        list.filter_map(ids, fn(id) {
          case campy_design.absolute(module.form.view, id) {
            Some(rect) -> Ok(rect)
            None -> Error(Nil)
          }
        })

      [
        ["selected", int.to_string(list.length(ids))],
        ["kind", common(list.map(nodes, fn(node) { node.kind }))],
        [
          "parent",
          common(
            list.map(nodes, fn(node) { parent_label(module.form.view, node.id) }),
          ),
        ],
        ["x", common(list.map(rects, fn(rect) { int.to_string(rect.x) }))],
        ["y", common(list.map(rects, fn(rect) { int.to_string(rect.y) }))],
        ["w", common(list.map(rects, fn(rect) { int.to_string(rect.w) }))],
        ["h", common(list.map(rects, fn(rect) { int.to_string(rect.h) }))],
        ["text", common(list.map(nodes, text_of))],
      ]
    }
  }
}

fn common(values: List(String)) -> String {
  case values {
    [] -> ""
    [first, ..rest] ->
      case list.all(rest, fn(value) { value == first }) {
        True -> first
        False -> ""
      }
  }
}

/// No selection: the dock inspects the window/form itself, matching the
/// reference IDE's default "Window" inspector. w/h and title are editable;
/// the rest is context.
fn summary_rows(state: model.State) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> [
      ["project", state.project.title],
      ["module", active_slug(state)],
    ]
    Ok(module) -> {
      let root = module.form.view
      let layout = campy_design.resolve(root)
      let rect = case campy_design.placed(layout, layout.root) {
        Some(placed) -> placed.rect
        None -> campy_design.Rect(0, 0, 600, 400)
      }
      [
        [
          "title",
          case campy_view.prop(root, "title") {
            Ok(VText(title)) -> title
            _ -> module.slug
          },
        ],
        ["w", int.to_string(rect.w)],
        ["h", int.to_string(rect.h)],
        [
          "layout",
          case campy_view.prop(root, "layout") {
            Ok(VText(layout)) -> layout
            _ -> "free"
          },
        ],
        ["module", module.slug],
        ["undo", int.to_string(list.length(state.undo))],
        ["redo", int.to_string(list.length(state.redo))],
      ]
    }
  }
}

/// One field per row, in a stable order. Identity fields come first and are
/// read-only; x/y/w/h and text are typed editors.
fn control_rows(state: model.State, id: String) -> List(List(String)) {
  case model.active_module(state) {
    Error(_) -> summary_rows(state)
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        None -> summary_rows(state)
        Some(node) -> {
          let rect = case campy_design.absolute(module.form.view, id) {
            Some(rect) -> rect
            None -> campy_design.Rect(0, 0, 0, 0)
          }
          [
            ["id", id],
            ["kind", node.kind],
            ["parent", parent_label(module.form.view, id)],
            ["x", int.to_string(rect.x)],
            ["y", int.to_string(rect.y)],
            ["w", int.to_string(rect.w)],
            ["h", int.to_string(rect.h)],
            ["text", text_of(node)],
          ]
        }
      }
  }
}

fn parent_label(root: Node, id: String) -> String {
  case campy_design.parent_of(root, id) {
    Some(parent) -> parent
    None -> "—"
  }
}

fn text_of(node: Node) -> String {
  case campy_view.prop(node, "text") {
    Ok(VText(text)) -> text
    _ -> ""
  }
}

fn active_slug(state: model.State) -> String {
  case state.active {
    Some(slug) -> slug
    None -> "—"
  }
}

fn canvas_node(state: model.State) -> Node {
  case model.active_module(state) {
    Ok(module) -> campy_design.design_view(module.form.view, "canvas")
    Error(_) ->
      campy_view.node("canvas", "canvas")
      |> campy_view.with_props([#("h", VInt(300)), #("w", VInt(400))])
      |> campy_view.with_events(["select"])
  }
}

fn view(state: model.State) -> Node {
  campy_view.node("window", "main")
  |> campy_view.with_props([
    #("title", VText("Campy")),
    #("w", VInt(1280)),
    #("h", VInt(860)),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    menubar(),
    toolbar(),
    palette_strip(state),
    status(state),
    body(state),
  ])
}

fn menubar() -> Node {
  campy_view.node("menubar", "menubar")
  |> campy_view.with_children([
    menu("file-menu", "File", [
      menu_item("menu-save", "Save            Ctrl+S"),
      menu_item("menu-quit", "Quit            Ctrl+Q"),
    ]),
    menu("edit-menu", "Edit", [
      menu_item("menu-undo", "Undo            Ctrl+Z"),
      menu_item("menu-redo", "Redo            Ctrl+Shift+Z"),
      menu_item("menu-cut", "Cut             Ctrl+X"),
      menu_item("menu-copy", "Copy            Ctrl+C"),
      menu_item("menu-paste", "Paste           Ctrl+V"),
      menu_item("menu-duplicate", "Duplicate       Ctrl+D"),
      menu_item("menu-delete", "Delete          Del"),
      menu_item("menu-front", "Bring to front"),
      menu_item("menu-back", "Send to back"),
      menu_item("menu-cancel-place", "Cancel placement    Esc"),
    ]),
    menu("view-menu", "View", [
      menu_item("menu-form", "Form            Ctrl+1"),
      menu_item("menu-code", "Code            Ctrl+2"),
      menu_item("menu-source", "Generated source    Ctrl+3"),
    ]),
    menu("help-menu", "Help", [
      menu_item("menu-help-keys", "Keyboard shortcuts    F1"),
    ]),
  ])
}

fn menu(id: String, label: String, items: List(Node)) -> Node {
  campy_view.node("menu", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_children(items)
}

fn menu_item(id: String, label: String) -> Node {
  campy_view.node("menuitem", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn toolbar() -> Node {
  campy_view.node("toolbar", "toolbar")
  |> campy_view.with_children([
    tool("tool-save", "Save"),
    tool("tool-undo", "Undo"),
    tool("tool-redo", "Redo"),
    tool_separator(),
    tool("tool-cut", "Cut"),
    tool("tool-copy", "Copy"),
    tool("tool-paste", "Paste"),
    tool("tool-duplicate", "Duplicate"),
    tool("tool-delete", "Delete"),
    tool_separator(),
    tool("tool-run", "Run"),
    tool("tool-stop", "Stop"),
  ])
}

fn tool(id: String, label: String) -> Node {
  campy_view.node("tool", id)
  |> campy_view.with_props([#("text", VText(label))])
  |> campy_view.with_events(["click"])
}

fn tool_separator() -> Node {
  campy_view.node("separator", "toolbar-separator")
}

fn status(state: model.State) -> Node {
  campy_view.node("status", "status")
  |> campy_view.with_props([#("text", VText(status_text(state)))])
}

fn body(state: model.State) -> Node {
  campy_view.node("panel", "body")
  |> campy_view.with_props([
    #("layout", VText("row")),
    #("border", VInt(2)),
    #("grow", VBool(True)),
  ])
  |> campy_view.with_children([
    navigator(state),
    centre(state),
    inspector(state),
  ])
}

/// Left navigator: project and module lists only. The widget palette lives in
/// the strip under the toolbar, not here.
fn navigator(state: model.State) -> Node {
  campy_view.node("panel", "nav")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(6)),
    #("w", VInt(200)),
  ])
  |> campy_view.with_children([
    campy_view.node("label", "projects-title")
      |> campy_view.with_props([#("text", VText("Projects"))]),
    campy_view.node("list", "projects")
      |> campy_view.with_props([
        #("h", VInt(52)),
        #("items", VList(list.map(project_items(state), VText))),
        #("selection", VInt(0)),
      ]),
    campy_view.node("label", "modules-title")
      |> campy_view.with_props([#("text", VText("Modules"))]),
    campy_view.node("list", "modules")
      |> campy_view.with_props([
        #("grow", VBool(True)),
        #("items", VList(list.map(module_items(state), VText))),
        #("selection", VInt(module_index(state))),
      ])
      |> campy_view.with_events(["change"]),
  ])
}

/// Centre: module/canvas header, Form/Code/Source notebook, then the console
/// header and read-only console editor. The console is not a right-dock pane.
fn centre(state: model.State) -> Node {
  campy_view.node("panel", "centre")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(2)),
    #("grow", VBool(True)),
  ])
  |> campy_view.with_children([
    campy_view.node("panel", "centre-header")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("h", VInt(26)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "centre-title")
        |> campy_view.with_props([
          #("text", VText(centre_header(state))),
          #("grow", VBool(True)),
        ]),
      ]),
    campy_view.node("notebook", "tabs")
      |> campy_view.with_props([#("grow", VBool(True))])
      |> campy_view.with_events(["change"])
      |> campy_view.with_children([
        form_page(state),
        code_page(),
        source_page(),
        run_page(state),
        nodes_page(state),
        debug_page(state),
      ]),
    campy_view.node("panel", "console-header")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("h", VInt(28)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "console-title")
          |> campy_view.with_props([#("text", VText("Console"))]),
        campy_view.node("label", "console-state")
          |> campy_view.with_props([#("text", VText("  stopped"))]),
        campy_view.node("label", "console-spacer")
          |> campy_view.with_props([
            #("text", VText("")),
            #("grow", VBool(True)),
          ]),
        campy_view.node("button", "console-clear")
          |> campy_view.with_props([
            #("text", VText("Clear")),
            #("tooltip", VText("Clear console")),
          ])
          |> campy_view.with_events(["click"]),
      ]),
    campy_view.node("editor", "console")
      |> campy_view.with_props([#("h", VInt(150))])
      |> campy_view.with_events([]),
  ])
}

fn form_page(state: model.State) -> Node {
  campy_view.node("page", "page-form")
  |> campy_view.with_props([
    #("text", VText("Form")),
    #("layout", VText("free")),
  ])
  |> campy_view.with_children([canvas_node(state)])
}

fn code_page() -> Node {
  campy_view.node("page", "page-code")
  |> campy_view.with_props([
    #("text", VText("Code")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("editor", "code")
    |> campy_view.with_props([#("grow", VBool(True))])
    |> campy_view.with_events([]),
  ])
}

/// Read-only generated construction source. The text is filled imperatively
/// from `campy_source`; this page only hosts the editor.
fn source_page() -> Node {
  campy_view.node("page", "page-source")
  |> campy_view.with_props([
    #("text", VText("Source")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("editor", "source")
    |> campy_view.with_props([#("grow", VBool(True))])
    |> campy_view.with_events([]),
  ])
}

/// The Debug page: the attached app's process list, its state snapshot, and
/// a send/receive trace toggle whose output lands in the console.
fn debug_page(state: model.State) -> Node {
  campy_view.node("page", "page-debug")
  |> campy_view.with_props([
    #("text", VText("Debug")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("panel", "debug-controls")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("h", VInt(34)),
      ])
      |> campy_view.with_children([
        campy_view.node("button", "debug-state")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Dump state"))]),
        campy_view.node("button", "debug-trace")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([
            #(
              "text",
              VText(case state.tracer {
                Some(_) -> "Stop tracing"
                None -> "Trace send/receive"
              }),
            ),
          ]),
        campy_view.node("button", "debug-refresh")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Refresh processes"))]),
      ]),
    campy_view.node("label", "debug-list-label")
      |> campy_view.with_props([
        #(
          "text",
          VText(
            "Processes on the app's node (pid, reductions, queue, initial call):",
          ),
        ),
      ]),
    campy_view.node("list", "debug-list")
      |> campy_view.with_props([
        #("grow", VBool(True)),
        #("items", VList([])),
      ]),
  ])
}

/// The Nodes page: start/stop peer BEAM nodes, deploy the active form to one,
/// and manage the app attached to it. Replies from a peer app arrive over
/// distribution on the same reply subject the in-VM run uses, so the console
/// and the Run page work identically for both.
fn nodes_page(state: model.State) -> Node {
  campy_view.node("page", "page-nodes")
  |> campy_view.with_props([
    #("text", VText("Nodes")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("panel", "nodes-controls")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("h", VInt(34)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "nodes-name-label")
          |> campy_view.with_props([#("text", VText("Peer name:"))]),
        campy_view.node("text", "nodes-name")
          |> campy_view.with_props([
            #("w", VInt(160)),
            #("text", VText(state.nodes_name)),
          ])
          |> campy_view.with_events(["change"]),
        campy_view.node("button", "nodes-start")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Start peer"))]),
        campy_view.node("button", "nodes-stop")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Stop peer"))]),
        campy_view.node("button", "nodes-deploy")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Deploy active form"))]),
        campy_view.node("button", "nodes-redeploy")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Redeploy (upgrade)"))]),
        campy_view.node("button", "nodes-app-stop")
          |> campy_view.with_events(["click"])
          |> campy_view.with_props([#("text", VText("Stop app"))]),
      ]),
    campy_view.node("label", "nodes-list-label")
      |> campy_view.with_props([
        #("text", VText("Peers (start one, select it, then deploy):")),
      ]),
    campy_view.node("list", "nodes-list")
      |> campy_view.with_props([
        #("grow", VBool(True)),
        #("items", VList(list.map(model.peer_nodes(state), VText))),
      ])
      |> campy_view.with_events(["select"]),
  ])
}

/// The Run page grafts the running app's published view into the IDE: the
/// form root becomes a panel (nested windows are not supported) with the
/// same children and props; its controls connect with normal (non-design)
/// events, which the shell routes to the running actor.
fn run_page(state: model.State) -> Node {
  campy_view.node("page", "page-run")
  |> campy_view.with_props([
    #("text", VText("Run")),
    #("layout", VText("free")),
  ])
  |> campy_view.with_children([preview_node(state)])
}

fn preview_node(state: model.State) -> Node {
  case state.live_view {
    Some(document) -> {
      let root = document.view
      campy_view.Node(
        kind: case root.kind {
          "form" | "window" -> "panel"
          kind -> kind
        },
        id: "preview-root",
        key: root.key,
        props: root.props,
        events: root.events,
        children: root.children,
        extra: root.extra,
      )
    }
    None ->
      campy_view.node("label", "preview-hint")
      |> campy_view.with_props([
        #("text", VText("Press Run to start the active form's app")),
      ])
  }
}

/// Right dock: selection header with Delete, then a native Properties/Events
/// notebook. Properties is a one-field-per-row grid; Events is its own page.
fn inspector(state: model.State) -> Node {
  campy_view.node("panel", "inspector-pane")
  |> campy_view.with_props([
    #("layout", VText("column")),
    #("border", VInt(4)),
    #("w", VInt(330)),
  ])
  |> campy_view.with_children([
    campy_view.node("panel", "inspector-header")
      |> campy_view.with_props([
        #("layout", VText("row")),
        #("border", VInt(4)),
        #("h", VInt(32)),
      ])
      |> campy_view.with_children([
        campy_view.node("label", "selection-title")
          |> campy_view.with_props([
            #("text", VText(selection_title(state))),
            #("grow", VBool(True)),
          ]),
        campy_view.node("button", "inspector-delete")
          |> campy_view.with_props([
            #("text", VText("Delete")),
            #("tooltip", VText("Delete selected controls (Del)")),
            #("enabled", VBool(!list.is_empty(state.selection))),
          ])
          |> campy_view.with_events(["click"]),
      ]),
    campy_view.node("notebook", "inspector-tabs")
      |> campy_view.with_props([#("grow", VBool(True))])
      |> campy_view.with_events(["change"])
      |> campy_view.with_children([properties_page(state), events_page(state)]),
  ])
}

fn properties_page(_state: model.State) -> Node {
  campy_view.node("page", "page-properties")
  |> campy_view.with_props([
    #("text", VText("Properties")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("grid", "inspector")
    |> campy_view.with_props([
      #("grow", VBool(True)),
      #("grid_labels", VBool(False)),
      #("grid_lines", VBool(False)),
      #("row_height", VInt(22)),
      #("label_width", VInt(110)),
    ])
    |> campy_view.with_events(["change"]),
  ])
}

fn events_page(state: model.State) -> Node {
  campy_view.node("page", "page-events")
  |> campy_view.with_props([
    #("text", VText("Events")),
    #("layout", VText("column")),
  ])
  |> campy_view.with_children([
    campy_view.node("label", "events-hint")
      |> campy_view.with_props([
        #("text", VText("Select an event to open or create its handler")),
      ]),
    campy_view.node("list", "events")
      |> campy_view.with_props([
        #("grow", VBool(True)),
        #("items", VList(list.map(events_display(state), VText))),
      ])
      |> campy_view.with_events(["change"]),
  ])
}

/// Compact palette strip under the toolbar. Buttons are symbol/text tools with
/// tooltips; clicking one arms placement and highlights that button.
fn palette_strip(state: model.State) -> Node {
  campy_view.node("panel", "palette-strip")
  |> campy_view.with_props([
    #("layout", VText("row")),
    #("border", VInt(3)),
  ])
  |> campy_view.with_children(list.append(
    [
      campy_view.node("label", "palette-title")
      |> campy_view.with_props([#("text", VText("Widgets"))]),
    ],
    list.map(campy_catalog.all(), fn(widget) {
      let armed = state.armed == Some(widget.kind)
      campy_view.node("button", "palette-" <> widget.kind)
      |> campy_view.with_props([
        #("text", VText(palette_label(widget.kind))),
        #("tooltip", VText(palette_tooltip(widget))),
        #("w", VInt(62)),
        #("h", VInt(28)),
        #("highlight", VBool(armed)),
      ])
      |> campy_view.with_events(["click"])
    }),
  ))
}

fn palette_label(kind: String) -> String {
  case kind {
    "text" -> "Text"
    "checkbox" -> "Check"
    "radio" -> "Radio"
    "list" -> "List"
    "progress" -> "Progress"
    _ -> campy_catalog.label_of(kind)
  }
}

fn palette_tooltip(widget: campy_catalog.Widget) -> String {
  palette_label(widget.kind) <> " — click, then drag on the form"
}

pub fn palette_labels() -> List(String) {
  list.map(campy_catalog.all(), fn(widget) { palette_label(widget.kind) })
}
