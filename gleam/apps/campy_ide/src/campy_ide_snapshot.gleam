import campy_bridge as bridge
import campy_form
import campy_form/live_preview
import campy_form/preview
import campy_form/project
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/state
import gleam/io
import gleam/list
import gleam/option.{Some}

@external(erlang, "campy_host_ffi", "generated_path")
fn generated_path(name: String) -> String

// `just snapshot-ide` loads the IDE shell exactly once, then renders every
// state by updating properties and models on that same live instance. No
// screenshot after the first one involves a LoadUi, which also demonstrates
// that structural changes (add control, new tab, code) no longer reload.
pub fn main() {
  let model = state.initial(project.campy())
  let assert Ok(shell) = ide_ui.to_slint(model)

  let assert Ok(session) = bridge.open_session()
  let assert Ok(_) = bridge.submit(session, bridge.LoadUi(1, shell))
  wait_for(1, "ui-loaded", "shell")

  let last =
    apply(
      session,
      ide_ui.snapshot(model),
      ide_ui.without_models(ide_ui.snapshot(model)),
    )
  snapshot(session, "ide-smoke.png")

  let widgets = state.open_module(model, "widgets")
  let last = apply(session, ide_ui.snapshot(widgets), last)
  snapshot(session, "ide-widgets.png")
  let last = apply(session, ide_ui.snapshot(model), last)

  let code = state.set_view(model, state.CodeView)
  let last = apply(session, ide_ui.snapshot(code), last)
  snapshot(session, "ide-code.png")

  let editing =
    model
    |> state.select("pet-button")
    |> state.open_event("clicked")
  let last = apply(session, ide_ui.snapshot(editing), last)
  snapshot(session, "ide-edit.png")

  let opening = state.set_popup(model, state.OpenFile)
  let last = apply(session, ide_ui.snapshot(opening), last)
  snapshot(session, "ide-open.png")

  let settings = state.set_settings_open(model, True)
  let last = apply(session, ide_ui.snapshot(settings), last)
  snapshot(session, "ide-settings.png")

  let slint = state.set_slint_tab(model, True)
  let last = apply(session, ide_ui.snapshot(slint), last)
  snapshot(session, "ide-slint.png")

  let light =
    state.set_scheme(state.set_settings_open(model, False), state.Light)
  let last = apply(session, ide_ui.snapshot(light), last)
  snapshot(session, "ide-light.png")

  let selected = state.select(model, "pet-button")
  let last = apply(session, ide_ui.snapshot(selected), last)
  snapshot(session, "ide-updated.png")

  // Structural edit: add a control. Still just a model update (no reload).
  let added = state.add(model, campy_form.Button)
  let last = apply(session, ide_ui.snapshot(added), last)
  snapshot(session, "ide-structure.png")

  // New components: a list and a panel on a fresh module.
  let showcase =
    model
    |> state.new_module()
    |> state.add(campy_form.ListBox)
    |> state.add(campy_form.Panel)
    |> state.move_selected(326, 0)
  let last = apply(session, ide_ui.snapshot(showcase), last)
  snapshot(session, "ide-components.png")

  // Column layout: Slint places the controls; the host sends no geometry.
  let column = state.set_layout(model, campy_form.Column)
  let last = apply(session, ide_ui.snapshot(column), last)
  snapshot(session, "ide-layout.png")

  let multi =
    model
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  let last = apply(session, ide_ui.snapshot(multi), last)
  snapshot(session, "ide-multiselect.png")

  let dropping =
    model
    |> state.select("pet-button")
    |> state.begin_drag
    |> state.set_drop_x(700)
    |> state.update_drop(10)
  let last = apply(session, ide_ui.snapshot(dropping), last)
  snapshot(session, "ide-drop-target.png")

  let placing = state.arm_component(model, "button")
  let last = apply(session, ide_ui.snapshot(placing), last)
  snapshot(session, "ide-place.png")

  let assert Ok(_) =
    bridge.submit(session, bridge.SetBool(1, "shift-down", True))
  let assert Ok(_) = bridge.submit(session, bridge.ReadText(1, "status"))
  wait_for(1, "property:status", "select-mode barrier")
  snapshot(session, "ide-select-mode.png")
  let assert Ok(_) =
    bridge.submit(session, bridge.SetBool(1, "shift-down", False))

  let console =
    model
    |> state.log_console("$ campy demo")
    |> state.log_console("App ready")
    |> state.log_console("Event: pet_button_clicked")
  let last = apply(session, ide_ui.snapshot(console), last)
  snapshot(session, "ide-console.png")

  let project_properties = state.switch_project(model, model.project.path)
  let last = apply(session, ide_ui.snapshot(project_properties), last)
  snapshot(session, "ide-project.png")

  let context = state.open_context_menu(model, "pet-button")
  let last = apply(session, ide_ui.snapshot(context), last)
  snapshot(session, "ide-context.png")

  let project_dialog = state.set_project_dialog_open(model, True)
  let last = apply(session, ide_ui.snapshot(project_dialog), last)
  snapshot(session, "ide-project-dialog.png")

  let welcome = state.open_module(model, "welcome")
  let last = apply(session, ide_ui.snapshot(welcome), last)
  snapshot(session, "ide-welcome.png")

  let agent = state.set_agent_open(model, True)
  let last = apply(session, ide_ui.snapshot(agent), last)
  snapshot(session, "ide-agent.png")

  let two_projects = state.create_project(model)
  let _last = apply(session, ide_ui.snapshot(two_projects), last)
  snapshot(session, "ide-workspace.png")

  let _ = bridge.close_session(session)

  let assert Some(form) = state.active_form(model)
  let assert Ok(form_source) = preview.to_slint(form)
  let path = generated_path("ide-form.png")
  let assert Ok(preview_session) = bridge.open_session()
  let assert Ok(_) =
    bridge.submit(preview_session, bridge.LoadUi(1, form_source))
  wait_for(1, "ui-loaded", "ide-form.png")
  let assert Ok(_) = bridge.submit(preview_session, bridge.Snapshot(1, path))
  wait_for(1, "snapshot-saved", "ide-form.png")
  let _ = bridge.close_session(preview_session)

  // Live app: load the shell once, then update the same window (the F6 path).
  let assert Ok(app_session) = bridge.open_session()
  let assert Ok(_) =
    bridge.submit(app_session, bridge.LoadUi(1, live_preview.to_slint()))
  wait_for(1, "ui-loaded", "app-live.png")
  let assert Ok(_) =
    live_preview_ui.apply(app_session, live_preview.snapshot(form))
  let assert Ok(_) = bridge.submit(app_session, bridge.ReadText(1, "app-title"))
  wait_for(1, "property:app-title", "app-live barrier")
  snapshot(app_session, "app-live.png")

  let updated =
    campy_form.update_selected(form, "pet-button", fn(control) {
      campy_form.Control(..control, text: "Purr!", y: 280)
    })
  let assert Ok(_) =
    live_preview_ui.apply(app_session, live_preview.snapshot(updated))
  let assert Ok(_) = bridge.submit(app_session, bridge.ReadText(1, "app-title"))
  wait_for(1, "property:app-title", "app-updated barrier")
  snapshot(app_session, "app-updated.png")
  let _ = bridge.close_session(app_session)

  io.println("IDE snapshots written")
}

fn apply(
  session: bridge.Session,
  next: ide_ui.Snapshot,
  last: ide_ui.Snapshot,
) -> ide_ui.Snapshot {
  list.each(ide_ui.diff(last.scalars, next.scalars), fn(change) {
    let command = case change {
      ide_ui.TextUpdate(name, value) -> bridge.SetText(1, name, value)
      ide_ui.BoolUpdate(name, value) -> bridge.SetBool(1, name, value)
      ide_ui.IntUpdate(name, value) -> bridge.SetInt(1, name, value)
      ide_ui.ScalarIntUpdate(name, value) -> bridge.SetInt(1, name, value)
      ide_ui.ColorUpdate(name, value) -> bridge.SetColor(1, name, value)
    }
    submit_retry(session, command)
  })
  case next.projects == last.projects {
    False ->
      submit_retry(
        session,
        bridge.SetModel(1, "project-items", ide_ui.projects_wire(next.projects)),
      )
    True -> Nil
  }
  case next.modules == last.modules {
    False ->
      submit_retry(
        session,
        bridge.SetModel(1, "module-items", ide_ui.modules_wire(next.modules)),
      )
    True -> Nil
  }
  case next.tabs == last.tabs {
    False ->
      submit_retry(
        session,
        bridge.SetModel(1, "tab-items", ide_ui.tabs_wire(next.tabs)),
      )
    True -> Nil
  }
  case next.controls == last.controls {
    False ->
      submit_retry(
        session,
        bridge.SetModel(1, "control-items", ide_ui.controls_wire(next.controls)),
      )
    True -> Nil
  }
  case next.code == last.code {
    False ->
      submit_retry(
        session,
        bridge.SetModel(1, "code-lines", ide_ui.code_wire(next.code)),
      )
    True -> Nil
  }
  submit_retry(session, bridge.ReadText(1, "status"))
  wait_for(1, "property:status", "barrier")
  next
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

fn snapshot(session: bridge.Session, name: String) -> Nil {
  io.println("snapshot " <> name)
  let path = generated_path(name)
  submit_retry(session, bridge.Snapshot(1, path))
  wait_for(1, "snapshot-saved", name)
}

@external(erlang, "campy_host_ffi", "now_ms")
fn now_ms() -> Int

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
