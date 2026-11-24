// `just snapshot-ide`: drive the live IDE shell through its states with the
// protocol-v2 op layer and verify every step against the real renderer.
//
// The shell is loaded once; each state change is applied as the granular ops
// `ide_ui.ops` derives from the previous view (a `Reload` re-loads the whole
// document at the next generation, exactly like F6). Each step ends with a
// `ReadText` barrier on the status line, so a rejected op fails the run
// instead of going unnoticed.
//
// Protocol v2 has no snapshot command (the renderer's headless scene dump is
// Z4.1), so this harness asserts state flow rather than writing PNGs.

import campy_bridge as bridge
import campy_form
import campy_form/project
import campy_ide/ide_ui
import campy_ide/shell
import campy_ide/state
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}

@external(erlang, "campy_host_ffi", "now_ms")
fn now_ms() -> Int

type Step {
  Step(name: String, model: state.State)
}

pub fn main() {
  let model = state.initial(project.campy())
  let view = ide_ui.snapshot(model)

  let assert Ok(session) = bridge.open_session()
  submit_commands(session, ide_ui.commands(1, [ide_ui.Reload(view)]))
  wait_for(1, "ui-loaded", "shell")

  // The first sync replays the content a document cannot carry (console,
  // marks, the editor buffer).
  let start = ide_ui.without_content(view)
  let steps = [
    Step("shell", model),
    Step("widgets", state.open_module(model, "widgets")),
    Step("code view", state.set_view(model, state.CodeView)),
    Step(
      "handler editor",
      model
        |> state.select("pet-button")
        |> state.open_event("clicked"),
    ),
    Step("file dialog", state.set_popup(model, state.OpenFile)),
    Step("settings", state.set_settings_open(model, True)),
    Step(
      "light theme",
      state.set_scheme(state.set_settings_open(model, False), state.Light),
    ),
    Step("selection", state.select(model, "pet-button")),
    // Structural edit: adding a control changes the canvas subtree.
    Step("structure", state.add(model, campy_form.Button)),
    Step(
      "components",
      model
        |> state.new_module()
        |> state.add(campy_form.ListBox)
        |> state.add(campy_form.Panel)
        |> state.move_selected(326, 0),
    ),
    Step("layout", state.set_layout(model, campy_form.Column)),
    Step(
      "multiselect",
      model
        |> state.select("pet-button")
        |> state.toggle_select("feed-button"),
    ),
    // A live marquee: the rectangle moves with SetGeometry while the pointer
    // is down, and the release commits the frame selection.
    Step(
      "marquee",
      model
        |> state.pointer_down(100, 100)
        |> state.pointer_move(300, 300),
    ),
    Step(
      "drop target",
      model
        |> state.select("pet-button")
        |> state.begin_drag("pet-button")
        |> state.set_drop_x(700)
        |> state.update_drop(10),
    ),
    Step("placement", state.arm_component(model, "button")),
    Step(
      "console",
      model
        |> state.log_console("$ campy demo")
        |> state.log_console("App ready")
        |> state.log_console("Event: pet_button_clicked"),
    ),
    Step("project", state.switch_project(model, model.project.path)),
    Step(
      "container",
      model
        |> state.select("panel-1")
        |> state.commit_field("border", "12"),
    ),
    Step("context menu", state.open_context_menu(model, "pet-button;200;200")),
    Step("project dialog", state.set_project_dialog_open(model, True)),
    Step("welcome", state.open_module(model, "welcome")),
    Step("agent", state.set_agent_open(model, True)),
    Step("workspace", state.create_project(model)),
  ]

  let #(_last, _generation) =
    list.fold(steps, #(start, 1), fn(acc, step) {
      let #(last, generation) = acc
      apply(session, generation, step.model, last, step.name)
    })

  let _ = bridge.close_session(session)
  io.println("IDE snapshots written")
}

// Apply `model`'s ops against the live document at `generation`, ending with a
// status-line barrier. A `Reload` re-loads the document (generation + 1).
fn apply(
  session: bridge.Session,
  generation: Int,
  model: state.State,
  last: ide_ui.Snapshot,
  name: String,
) -> #(ide_ui.Snapshot, Int) {
  let next = ide_ui.snapshot(model)
  let ops = ide_ui.ops(last, next)
  case has_reload(ops) {
    True -> apply_reload(session, generation, next, name)
    False -> {
      submit_commands(session, ide_ui.commands(generation, ops))
      barrier(session, generation, name)
      #(next, generation)
    }
  }
}

fn apply_reload(
  session: bridge.Session,
  generation: Int,
  next: ide_ui.Snapshot,
  name: String,
) -> #(ide_ui.Snapshot, Int) {
  let generation = generation + 1
  submit_commands(session, ide_ui.commands(generation, [ide_ui.Reload(next)]))
  wait_for(generation, "ui-loaded", name)
  // Replay the content the new document cannot carry.
  let baseline = ide_ui.without_content(next)
  submit_commands(
    session,
    ide_ui.commands(generation, ide_ui.ops(baseline, next)),
  )
  barrier(session, generation, name)
  #(next, generation)
}

fn has_reload(ops: List(ide_ui.UiOp)) -> Bool {
  list.any(ops, fn(op) {
    case op {
      ide_ui.Reload(_) -> True
      _ -> False
    }
  })
}

fn submit_commands(
  session: bridge.Session,
  commands: List(bridge.Command),
) -> Nil {
  list.each(commands, fn(command) { submit_retry(session, command) })
}

fn submit_retry(session: bridge.Session, command: bridge.Command) -> Nil {
  case bridge.submit(session, command) {
    Ok(_) -> Nil
    Error(_) -> {
      let _ = bridge.poll(10)
      submit_retry(session, command)
    }
  }
}

// The status line is a plain label: reading it proves every op before it
// applied, and surfaces a `command-failed` as a hard failure.
fn barrier(session: bridge.Session, generation: Int, name: String) -> Nil {
  let id = shell.section_id("status")
  submit_retry(session, bridge.ReadText(generation, id, "text"))
  wait_for(generation, "read:" <> int.to_string(id) <> ":text", name)
}

fn wait_for(generation: Int, kind: String, name: String) -> Nil {
  wait_for_loop(generation, kind, name, now_ms())
}

fn wait_for_loop(
  generation: Int,
  kind: String,
  name: String,
  start: Int,
) -> Nil {
  case now_ms() - start > 120_000 {
    True -> {
      io.println("snapshot " <> name <> " timed out waiting for " <> kind)
      panic
    }
    False -> Nil
  }
  case bridge.poll(500) {
    Some(bridge.NativeEvent(_, received, event_kind, _))
      if received >= generation && event_kind == kind
    -> Nil
    Some(bridge.NativeEvent(_, _, "command-failed", payload)) -> {
      io.println("snapshot " <> name <> " failed: " <> payload)
      panic
    }
    Some(bridge.NativeEvent(_, _, "runtime-failed", payload)) -> {
      io.println("snapshot " <> name <> " failed: " <> payload)
      panic
    }
    _ -> wait_for_loop(generation, kind, name, start)
  }
}
