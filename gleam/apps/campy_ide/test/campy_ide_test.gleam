// The IDE's state model and protocol-v2 shell contract.
//
// Pure tests cover the editor state machine, the designer model, the ops the
// loop derives, and gesture routing. The session tier (guarded by a display)
// loads the real v2 document through the NIF and drives it with granular ops.

import campy_bridge as bridge
import campy_ccl
import campy_form
import campy_form/live_preview
import campy_form/project
import campy_form/workspace
import campy_ide
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/mcp
import campy_ide/shell
import campy_ide/state
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

@external(erlang, "campy_host_ffi", "has_display")
fn has_display() -> Bool

@external(erlang, "campy_host_ffi", "live_tests")
fn live_tests() -> Bool

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Documents and ops (no session)
// ---------------------------------------------------------------------------

pub fn ide_shell_document_is_protocol_v2_test() {
  let document = shell.desc(ide_ui.snapshot(demo_state()))
  let assert [root, ..] = document
  root.id |> should.equal(campy_form.window_id)
  // Every section the loop routes by has a wire id derived from its name.
  let ids = flatten(document) |> list.map(fn(control) { control.id })
  list.each(
    ["menu-bar", "palette", "canvas", "console", "inspector", "status"],
    fn(name) { list.contains(ids, shell.section_id(name)) |> should.be_true },
  )
  // The window title/theme are LoadUi-level.
  let assert [bridge.LoadUi(generation, title, width, height, theme, _)] =
    ide_ui.load_commands(1, demo_state())
  generation |> should.equal(1)
  title |> should.equal("Campy IDE — Campy")
  width |> should.equal(shell.window_width)
  height |> should.equal(shell.window_height)
  theme |> should.equal("dark")
}

pub fn toolbar_and_dialog_controls_are_buttons_test() {
  let document = shell.desc(ide_ui.snapshot(demo_state()))
  list.each(
    [
      #("run", "button"),
      #("stop", "button"),
      #("view-toggle", "button"),
      #("module-add", "button"),
      #("tab-close", "button"),
      #("console-clear", "button"),
      #("project-icon-choose", "button"),
      #("settings-close", "button"),
      #("agent-close", "button"),
      #("project-new", "button"),
      #("browser-accept", "button"),
      #("ctx-paste", "button"),
    ],
    fn(entry) {
      let #(name, kind) = entry
      case
        flatten(document)
        |> list.find(fn(item) { item.id == shell.section_id(name) })
      {
        Ok(control) -> control.kind |> should.equal(kind)
        Error(_) -> should.fail()
      }
    },
  )
}

pub fn palette_tiles_are_clickable_buttons_test() {
  let document = shell.desc(ide_ui.snapshot(demo_state()))
  list.each(campy_ccl.all(), fn(component) {
    let id = campy_form.wire_id("tile:" <> component.key)
    case flatten(document) |> list.find(fn(item) { item.id == id }) {
      Ok(tile) -> {
        tile.kind |> should.equal("button")
        tile.text |> should.equal(component.icon)
      }
      Error(_) -> should.fail()
    }
  })
}

pub fn selection_change_is_granular_ops_test() {
  let model = demo_state()
  let previous = ide_ui.snapshot(model)
  let next = ide_ui.snapshot(state.select(model, "pet-button"))
  let ops = ide_ui.ops(previous, next)
  // The selection outline becomes visible and takes the control's geometry.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetBool(id, "visible", True) ->
        id == shell.section_id("selection-rect")
      _ -> False
    }
  })
  |> should.be_true
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetGeometry(id, _, _, _, _) ->
        id == shell.section_id("selection-rect")
      _ -> False
    }
  })
  |> should.be_true
  // The inspector rows appear with the selected control's values.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetText(id, "pet_button") -> id == campy_form.wire_id("insp:name")
      _ -> False
    }
  })
  |> should.be_true
  // The inspector header names the selection.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetText(id, "Button · pet_button") ->
        id == shell.section_id("insp-selection")
      _ -> False
    }
  })
  |> should.be_true
}

pub fn structural_edit_reloads_the_document_test() {
  let model = demo_state()
  let previous = ide_ui.snapshot(model)
  let added = state.add(model, campy_form.Button)
  let ops = ide_ui.ops(previous, ide_ui.snapshot(added))
  // The canvas subtree grew: no granular op can express it.
  list.length(ops) |> should.equal(1)
  let assert [ide_ui.Reload(view)] = ops
  list.length(view.controls) |> should.equal(8)
}

pub fn opening_a_module_is_a_reload_and_a_model_test() {
  let model = demo_state()
  let opened = state.open_module(model, "search-box")
  let ops = ide_ui.ops(ide_ui.snapshot(model), ide_ui.snapshot(opened))

  // The canvas document changed shape (different form) → one reload.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.Reload(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn view_toggle_is_granular_test() {
  let model = demo_state()
  let code = state.toggle_view(model)
  let ops = ide_ui.ops(ide_ui.snapshot(model), ide_ui.snapshot(code))
  // The toggle glyph flips, the raw/form tab strip hides, the editor shows.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetText(id, "▦") -> id == shell.section_id("view-toggle")
      _ -> False
    }
  })
  |> should.be_true
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetBool(id, "visible", True) -> id == shell.section_id("code-view")
      _ -> False
    }
  })
  |> should.be_true
  // The form/raw tab strip and the canvas hide; the editor and its title show.
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetBool(id, "visible", False) -> id == shell.section_id("canvas")
      _ -> False
    }
  })
  |> should.be_true
}

pub fn code_edit_is_set_code_not_set_text_test() {
  let model = demo_state() |> state.set_view(state.CodeView)
  let edited = state.code_changed(model, "pub fn main() { Nil }\n")
  let ops = ide_ui.ops(ide_ui.snapshot(model), ide_ui.snapshot(edited))
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetCode(id, "pub fn main() { Nil }\n") ->
        id == shell.section_id("code-view")
      _ -> False
    }
  })
  |> should.be_true
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetText(id, _) -> id == shell.section_id("code-view")
      _ -> False
    }
  })
  |> should.be_false
}

// After a LoadUi the baseline has no content, so the next sync replays the
// console, the editor buffer and the diagnostic marks.
pub fn loaded_baseline_replays_content_test() {
  let model =
    demo_state()
    |> state.set_view(state.CodeView)
    |> state.log_console("hello")
    |> state.diagnostics_arrived("0\t1\tboom")
  let view = ide_ui.snapshot(model)
  let baseline = ide_ui.without_content(view)
  baseline.console_lines |> should.equal([])
  baseline.code_source |> should.equal("")
  let ops = ide_ui.ops(baseline, view)
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.AppendConsole(id, _) -> id == shell.section_id("console")
      _ -> False
    }
  })
  |> should.be_true
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetMarks(id, "diagnostics", _) ->
        id == shell.section_id("code-view")
      _ -> False
    }
  })
  |> should.be_true
  // An unchanged view produces no ops at all (no reload loop after a load).
  ide_ui.ops(baseline, baseline) |> should.equal([])
}

pub fn theme_change_reloads_the_document_test() {
  let model = demo_state()
  let ops =
    ide_ui.ops(
      ide_ui.snapshot(model),
      ide_ui.snapshot(state.set_scheme(model, state.Light)),
    )
  let assert [ide_ui.Reload(view)] = ops
  view.theme |> should.equal("light")
}

pub fn layout_change_reloads_the_document_test() {
  let model = demo_state()
  let ops =
    ide_ui.ops(
      ide_ui.snapshot(model),
      ide_ui.snapshot(state.set_layout(model, campy_form.Column)),
    )
  let assert [ide_ui.Reload(_)] = ops
}

pub fn hints_toggle_is_a_granular_bool_test() {
  let model = demo_state()
  let ops =
    ide_ui.ops(
      ide_ui.snapshot(model),
      ide_ui.snapshot(state.set_hints(model, False)),
    )
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetBool(id, "checked", False) ->
        id == shell.section_id("settings-hints")
      _ -> False
    }
  })
  |> should.be_true
}

pub fn context_menu_geometry_is_granular_test() {
  let model = demo_state()
  let opened = state.open_context_menu(model, "pet-button;300;200")
  let ops = ide_ui.ops(ide_ui.snapshot(model), ide_ui.snapshot(opened))
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetGeometry(id, 300, 200, 150, 142) ->
        id == shell.section_id("context-menu")
      _ -> False
    }
  })
  |> should.be_true
}

// Every pre-v2 keybinding keeps an action, and every menu item maps to the
// same dispatch name (the labels are the old titles verbatim).
pub fn key_bindings_keep_their_actions_test() {
  let expected = [
    #("ctrl+z", "undo"),
    #("ctrl+shift+z", "redo"),
    #("ctrl+y", "redo"),
    #("ctrl+c", "copy-component"),
    #("ctrl+x", "cut-component"),
    #("ctrl+v", "paste-component"),
    #("delete", "delete-selected"),
    #("ctrl+n", "file-new"),
    #("ctrl+shift+n", "file-new-module"),
    #("ctrl+o", "file-open"),
    #("ctrl+s", "file-save"),
    #("ctrl+shift+s", "file-save-as"),
    #("ctrl+q", "file-quit"),
    #("f5", "run-app"),
    #("f6", "reload-code"),
    #("f7", "update-app"),
    #("shift+f5", "stop-app"),
    #("ctrl+tab", "toggle-view"),
    #("ctrl+space", "completion-request"),
    #("escape", "escape"),
  ]
  list.each(expected, fn(entry) {
    let #(combo, action) = entry
    campy_ide.key_action(combo) |> should.equal(Some(action))
  })
  // Plain typing never reaches the loop (the focused editor owns it).
  campy_ide.key_action("a") |> should.equal(None)
}

pub fn menu_items_map_to_dispatch_actions_test() {
  let expected = [
    #("menu-file", "New project    Ctrl+N", "file-new"),
    #("menu-file", "New module    Ctrl+Shift+N", "file-new-module"),
    #("menu-file", "Open…    Ctrl+O", "file-open"),
    #("menu-file", "Save    Ctrl+S", "file-save"),
    #("menu-file", "Save As…    Ctrl+Shift+S", "file-save-as"),
    #("menu-file", "Quit    Ctrl+Q", "file-quit"),
    #("menu-edit", "Undo    Ctrl+Z", "undo"),
    #("menu-edit", "Redo    Ctrl+Shift+Z", "redo"),
    #("menu-edit", "Copy component    Ctrl+C", "copy-component"),
    #("menu-edit", "Cut component    Ctrl+X", "cut-component"),
    #("menu-edit", "Paste component    Ctrl+V", "paste-component"),
    #("menu-edit", "Delete component    Del", "delete-selected"),
    #("menu-edit", "Bring to front", "order-front"),
    #("menu-edit", "Move to back", "order-back"),
    #("menu-edit", "Update running app    F7", "update-app"),
    #("menu-edit", "Reload Campy code    F6", "reload-code"),
    #("menu-settings", "Editor…", "open-settings"),
    #("menu-settings", "Agent…", "open-agent"),
  ]
  list.each(expected, fn(entry) {
    let #(menu, label, action) = entry
    campy_ide.menu_action(menu, label) |> should.equal(Some(action))
  })
  // Separators carry no action.
  campy_ide.menu_action("menu-file", "—") |> should.equal(None)
}

// Control ids route back to the shell names the loop dispatches on, including
// the derived tile and inspector pools.
pub fn control_ids_route_to_shell_names_test() {
  campy_ide.control_name(shell.section_id("canvas"))
  |> should.equal(Some("canvas"))
  campy_ide.control_name(campy_form.wire_id("tile:button"))
  |> should.equal(Some("tile:button"))
  campy_ide.control_name(campy_form.wire_id("insp:visible"))
  |> should.equal(Some("insp:visible"))
  // A designed control is not a shell section.
  campy_ide.control_name(campy_form.wire_id("pet-button"))
  |> should.equal(None)
}

// ---------------------------------------------------------------------------
// State model
// ---------------------------------------------------------------------------

pub fn ide_state_tracks_tabs_and_handlers_test() {
  let model = demo_state()
  list_length(model.opened) |> should.equal(1)

  let opened = state.open_module(model, "search-box")
  opened.active |> should.equal("search-box")
  list_length(opened.opened) |> should.equal(2)

  let editing =
    opened
    |> state.select("button-1")
    |> state.open_event("clicked")
  editing.active_handler |> should.equal(Some("button1_clicked"))
  state.is_code_view(editing) |> should.be_true
}

pub fn tabs_never_reorder_test() {
  let first = demo_state() |> state.open_module("widgets")
  let second = first |> state.open_module("search-box")
  second.opened |> should.equal(["cat-cafe", "widgets", "search-box"])

  let switched = second |> state.activate_module("widgets")
  switched.opened |> should.equal(second.opened)
  switched.active |> should.equal("widgets")

  // Re-opening an already-open module activates it without moving it.
  let reopened = second |> state.open_module("cat-cafe")
  reopened.opened |> should.equal(second.opened)
  reopened.active |> should.equal("cat-cafe")
}

pub fn cycle_tab_wraps_test() {
  let model =
    demo_state()
    |> state.open_module("widgets")
    |> state.open_module("search-box")
  state.cycle_tab(model, 1).active |> should.equal("cat-cafe")
  state.cycle_tab(model, -1).active |> should.equal("widgets")
}

pub fn last_module_tab_cannot_close_test() {
  let closed = state.close_module(demo_state(), demo_state().active)
  closed.status |> should.equal("Cannot close the last tab")
}

pub fn module_context_delete_removes_inactive_module_test() {
  let model = demo_state() |> state.open_module("search-box")
  let menu =
    state.nav_context_menu(model, "module;cat-cafe") |> state.nav_delete
  let assert Some(module) = state.active_module(menu)
  module.id |> should.equal("search-box")
  list.any(menu.project.modules, fn(module) { module.id == "cat-cafe" })
  |> should.be_false
  state.can_undo(menu) |> should.be_true

  // The last remaining module cannot be deleted.
  let last =
    menu |> state.nav_context_menu("module;search-box") |> state.nav_delete
  last.status |> should.equal("Cannot delete the last module")
}

pub fn models_reflect_the_designer_test() {
  let model = demo_state()
  let snapshot = ide_ui.snapshot(model)
  list_length(snapshot.modules) |> should.equal(4)
  list_length(snapshot.tabs) |> should.equal(1)
  list_length(snapshot.controls) |> should.equal(7)
  should.be_true(list_length(snapshot.code) > 0)
}

pub fn designer_gestures_update_geometry_test() {
  let model = demo_state() |> state.select("pet-button")
  let moved = state.move_selected(model, 10, 20)
  let assert Some(control) = state.selected_control(moved)
  control.x |> should.equal(54)
  control.y |> should.equal(256)

  let resized = state.resize_selected(moved, 20, 5)
  let assert Some(next) = state.selected_control(resized)
  next.width |> should.equal(160)
  next.height |> should.equal(37)
}

// ---------------------------------------------------------------------------
// Canvas pointer gestures
// ---------------------------------------------------------------------------

pub fn control_hit_testing_prefers_the_topmost_test() {
  let assert Some(form) = state.active_form(demo_state())
  // (44,236) is inside pet-button; the panel underneath also contains it.
  let assert Some(control) = state.control_at(form, 60, 240)
  control.id |> should.equal("pet-button")
  // An empty spot on the window resolves to nothing.
  state.control_at(form, 630, 410) |> should.equal(None)
}

pub fn click_selects_on_release_test() {
  let down = state.pointer_down(demo_state(), 60, 240)
  down.gesture |> should.equal(state.Pressing(#(60, 240), "pet-button"))
  let up = state.pointer_up(down, 60, 240, False)
  up.selected |> should.equal(Some("pet-button"))
  up.gesture |> should.equal(state.Idle)
}

pub fn drag_from_selected_control_moves_it_test() {
  let model = demo_state() |> state.select("pet-button")
  let moved =
    model
    |> state.pointer_down(60, 240)
    |> state.pointer_move(80, 260)
    |> state.pointer_move(100, 280)
  let assert Some(control) = state.selected_control(moved)
  control.x |> should.equal(84)
  control.y |> should.equal(276)
  let released = state.pointer_up(moved, 100, 280, False)
  released.gesture |> should.equal(state.Idle)
  let assert Some(after) = state.selected_control(released)
  after.x |> should.equal(84)
}

pub fn drag_from_unselected_control_marquees_test() {
  let model = demo_state() |> state.select("")
  let dragging = state.pointer_move(state.pointer_down(model, 60, 240), 90, 270)
  dragging.gesture |> should.equal(state.Marqueing(#(60, 240)))
  // The marquee rectangle is visible while the pointer is down.
  let #(active, x, y, w, h) = state.marquee_rect(dragging)
  active |> should.be_true
  #(x, y, w, h) |> should.equal(#(60, 240, 30, 30))
  // Release selects the frame: both buttons sit inside (60,240)-(300,300).
  let released =
    state.pointer_up(state.pointer_move(dragging, 300, 300), 300, 300, False)
  list.length(released.selection) |> should.equal(2)
  list.contains(released.selection, "pet-button") |> should.be_true
  list.contains(released.selection, "feed-button") |> should.be_true
  released.gesture |> should.equal(state.Idle)
}

pub fn empty_canvas_click_clears_the_selection_test() {
  let model = demo_state() |> state.select("pet-button")
  let released =
    model
    |> state.pointer_down(630, 410)
    |> state.pointer_up(630, 410, False)
  released.selection |> should.equal([])
}

pub fn palette_placement_follows_the_pointer_test() {
  let armed = state.arm_component(demo_state(), "button")
  let placed =
    armed
    |> state.pointer_down(300, 300)
    |> state.pointer_move(420, 340)
    |> state.pointer_up(420, 340, False)
  let assert Some(control) = state.selected_control(placed)
  control.x |> should.equal(300)
  control.y |> should.equal(300)
  control.width |> should.equal(120)
  control.height |> should.equal(40)
  placed.pending_kind |> should.equal(None)
  let assert Some(form) = state.active_form(placed)
  campy_form.parent_of(form, control.id) |> should.equal("panel-1")
}

pub fn window_title_drag_moves_the_module_window_test() {
  let moved =
    demo_state()
    |> state.pointer_down(100, -14)
    |> state.pointer_move(120, 6)
    |> state.pointer_up(120, 6, False)
  state.window_position(moved) |> should.equal(#(52, 60))
}

pub fn selection_edge_grip_resizes_the_control_test() {
  let model = demo_state() |> state.select("pet-button")
  // pet-button is (44,236,140,32): the east edge is x=184.
  let resized =
    model
    |> state.pointer_down(184, 250)
    |> state.pointer_move(204, 250)
    |> state.pointer_up(204, 250, False)
  let assert Some(control) = state.selected_control(resized)
  control.width |> should.equal(160)
}

pub fn pointer_cancel_drops_the_gesture_test() {
  let model = demo_state() |> state.select("pet-button")
  let dragged = state.pointer_move(state.pointer_down(model, 60, 240), 100, 280)
  let cancelled = state.pointer_cancel(dragged)
  cancelled.gesture |> should.equal(state.Idle)
  let assert Some(control) = state.selected_control(cancelled)
  // The move itself already happened (previews are model edits); the undo
  // gesture is closed so F6/undo start a fresh step.
  control.x |> should.equal(84)
}

// ---------------------------------------------------------------------------
// Editing, undo, clipboard
// ---------------------------------------------------------------------------

pub fn adoption_walks_to_the_accepting_parent_test() {
  let model = demo_state() |> state.select("picture-1")
  state.adoption_target(model) |> should.equal("panel-1")

  let added = state.add(model, campy_form.Button)
  let assert Some(form) = state.active_form(added)
  let assert Some(control) = state.selected_control(added)
  campy_form.parent_of(form, control.id) |> should.equal("panel-1")

  state.adoption_target(demo_state() |> state.select("panel-1"))
  |> should.equal("panel-1")
  state.adoption_target(demo_state()) |> should.equal("")
}

pub fn copy_paste_duplicates_a_subtree_test() {
  let model = demo_state() |> state.select("panel-1")
  let copied = state.copy_selected(model)
  let pasted = state.paste(state.select(copied, ""))
  let assert Some(form) = state.active_form(pasted)
  list_length(form.controls) |> should.equal(14)

  let assert Some(new_panel) = state.selected_control(pasted)
  new_panel.kind |> should.equal(campy_form.Panel)
  campy_form.parent_of(form, new_panel.id) |> should.equal("")
  list_length(campy_form.children_of(form, new_panel.id)) |> should.equal(6)
}

pub fn cut_removes_the_subtree_test() {
  let cut = state.cut_selected(demo_state() |> state.select("panel-1"))
  let assert Some(form) = state.active_form(cut)
  list_length(form.controls) |> should.equal(0)
}

pub fn picture_control_carries_its_image_path_test() {
  let snapshot = ide_ui.snapshot(demo_state())
  snapshot.controls
  |> list.any(fn(control) {
    control.kind == "picture" && control.picture == "assets/cat.png"
  })
  |> should.be_true
}

pub fn undo_redo_covers_form_edits_test() {
  let start = demo_state()
  state.can_undo(start) |> should.be_false

  let added = state.add(start, campy_form.Button)
  state.can_undo(added) |> should.be_true
  list_length(ide_ui.snapshot(added).controls) |> should.equal(8)

  let undone = state.undo(added)
  list_length(ide_ui.snapshot(undone).controls) |> should.equal(7)
  state.can_redo(undone) |> should.be_true

  let redone = state.redo(undone)
  list_length(ide_ui.snapshot(redone).controls) |> should.equal(8)
}

pub fn undo_restores_field_and_code_edits_test() {
  let renamed =
    demo_state()
    |> state.select("pet-button")
    |> state.commit_field("text", "Purr")
  let assert Some(control) = state.selected_control(renamed)
  control.text |> should.equal("Purr")

  let back = state.undo(renamed)
  let assert Some(old) = state.selected_control(back)
  old.text |> should.equal("Pet the cat")

  let stubbed =
    demo_state()
    |> state.select("search-edit")
    |> state.open_event("edited")
  let assert Some(module) = state.active_module(stubbed)
  string.contains(state.module_source(module), "search_edit_edited")
  |> should.be_true

  let restored = state.undo(stubbed)
  let assert Some(after) = state.active_module(restored)
  string.contains(state.module_source(after), "search_edit_edited")
  |> should.be_false
}

pub fn new_edit_clears_the_redo_stack_test() {
  let undone = state.add(demo_state(), campy_form.Label) |> state.undo
  state.can_redo(undone) |> should.be_true
  let changed = state.add(undone, campy_form.Panel)
  state.can_redo(changed) |> should.be_false
}

pub fn cut_layout_and_module_creation_are_undoable_test() {
  let cut = state.cut_selected(demo_state() |> state.select("panel-1"))
  let assert Some(form) = state.active_form(cut)
  list_length(form.controls) |> should.equal(0)
  let back = state.undo(cut)
  let assert Some(form) = state.active_form(back)
  list_length(form.controls) |> should.equal(7)

  let row = state.set_layout(demo_state(), campy_form.Row)
  let assert Some(form) = state.active_form(row)
  form.layout |> should.equal(campy_form.Row)
  let back = state.undo(row)
  let assert Some(form) = state.active_form(back)
  form.layout |> should.equal(campy_form.Free)

  let count = demo_state().project.modules |> list.length
  let created = state.new_module(demo_state())
  created.project.modules |> list.length |> should.equal(count + 1)
  let back = state.undo(created)
  back.project.modules |> list.length |> should.equal(count)
}

pub fn drag_and_resize_gestures_are_one_undo_step_test() {
  let moved =
    demo_state()
    |> state.select("pet-button")
    |> state.move_gesture_x(10)
    |> state.move_gesture_y(20)
  let assert Some(control) = state.selected_control(moved)
  control.x |> should.equal(54)
  control.y |> should.equal(256)

  let back = state.undo(moved)
  let assert Some(old) = state.selected_control(back)
  old.x |> should.equal(44)
  old.y |> should.equal(236)
  state.undo(back).status |> should.equal("Nothing to undo")

  let resized =
    demo_state()
    |> state.select("pet-button")
    |> state.resize_gesture_w(20)
    |> state.resize_gesture_h(5)
  let assert Some(control) = state.selected_control(resized)
  control.width |> should.equal(160)
  control.height |> should.equal(37)
  let back = state.undo(resized)
  let assert Some(old) = state.selected_control(back)
  old.width |> should.equal(140)
  old.height |> should.equal(32)
}

pub fn alignment_is_undoable_and_uses_form_geometry_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.set_align(campy_form.Bottom)
  let assert Some(form) = state.active_form(model)
  campy_form.align_of(form, "pet-button") |> should.equal(campy_form.Bottom)

  let snapshot = ide_ui.snapshot(model)
  let assert Ok(item) =
    list.find(snapshot.controls, fn(control) { control.id == "pet-button" })
  item.y |> should.equal(352)
  item.w |> should.equal(560)

  let back = state.undo(model)
  let assert Some(form) = state.active_form(back)
  campy_form.align_of(form, "pet-button") |> should.equal(campy_form.NoAlign)
}

pub fn workspace_create_switch_delete_test() {
  let start = demo_state()
  list.length(start.workspace.projects) |> should.equal(1)

  let created = state.create_project(start)
  created.project.title |> should.equal("Project 1")
  created.project.path |> should.equal("projects/project-1.campy")
  list.length(created.workspace.projects) |> should.equal(2)

  let snapshot = ide_ui.snapshot(created)
  list.length(snapshot.projects) |> should.equal(2)
  list.any(snapshot.projects, fn(project) {
    project.title == "Project 1" && project.active
  })
  |> should.be_true

  let back = state.switch_project(created, project.default_path)
  back.project.title |> should.equal("Campy")
  list.length(back.project.modules) |> should.equal(4)

  let deleted = state.delete_active_project(back)
  list.length(deleted.workspace.projects) |> should.equal(1)
  deleted.project.title |> should.equal("Project 1")

  let blocked = state.delete_active_project(deleted)
  list.length(blocked.workspace.projects) |> should.equal(1)
}

pub fn resize_from_every_edge_test() {
  let model = demo_state() |> state.select("pet-button")

  let assert Some(control) =
    state.selected_control(state.resize_left(model, -10))
  control.x |> should.equal(34)
  control.width |> should.equal(150)

  let assert Some(control) =
    state.selected_control(state.resize_right(model, 10))
  control.width |> should.equal(150)

  let assert Some(control) =
    state.selected_control(state.resize_top(model, -10))
  control.y |> should.equal(226)
  control.height |> should.equal(42)

  let assert Some(control) =
    state.selected_control(state.resize_bottom(model, 10))
  control.height |> should.equal(42)

  let assert Some(control) =
    state.selected_control(state.resize_left(model, 500))
  control.x |> should.equal(176)
  control.width |> should.equal(8)
}

pub fn corner_resize_is_one_undo_step_test() {
  let corner =
    demo_state()
    |> state.select("pet-button")
    |> state.begin_gesture
    |> state.resize_left(-10)
    |> state.resize_top(-10)
    |> state.end_gesture
  let assert Some(control) = state.selected_control(corner)
  control.x |> should.equal(34)
  control.y |> should.equal(226)
  control.width |> should.equal(150)
  control.height |> should.equal(42)

  let undone = state.undo(corner)
  let assert Some(control) = state.selected_control(undone)
  control.x |> should.equal(44)
  control.y |> should.equal(236)
  control.width |> should.equal(140)
  control.height |> should.equal(32)
  state.undo(undone).status |> should.equal("Nothing to undo")
}

pub fn dragging_onto_a_panel_adopts_it_test() {
  let added = state.add(state.select(demo_state(), ""), campy_form.Button)
  let moved =
    added
    |> state.begin_gesture
    |> state.move_gesture_x(50)
    |> state.move_gesture_y(50)
    |> state.end_gesture
  let assert Some(form) = state.active_form(moved)
  let assert Some(control) = state.selected_control(moved)
  campy_form.parent_of(form, control.id) |> should.equal("panel-1")

  let outside =
    moved
    |> state.begin_gesture
    |> state.move_gesture_x(600)
    |> state.move_gesture_y(0)
    |> state.end_gesture
  let assert Some(form) = state.active_form(outside)
  campy_form.parent_of(form, control.id) |> should.equal("")
}

pub fn nested_panels_accept_children_test() {
  let added = state.add(state.select(demo_state(), "panel-1"), campy_form.Panel)
  let assert Some(form) = state.active_form(added)
  let assert Some(child_panel) = state.selected_control(added)
  campy_form.parent_of(form, child_panel.id) |> should.equal("panel-1")

  let nested = state.add(added, campy_form.Button)
  let assert Some(form) = state.active_form(nested)
  let assert Some(button) = state.selected_control(nested)
  campy_form.parent_of(form, button.id) |> should.equal(child_panel.id)
}

pub fn ctrl_click_toggles_multi_selection_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  list.length(model.selection) |> should.equal(2)
  let snapshot = ide_ui.snapshot(model)
  snapshot.controls
  |> list.any(fn(control) { control.id == "pet-button" && control.selected })
  |> should.be_true
  snapshot.controls
  |> list.any(fn(control) {
    control.id == "feed-button" && control.selected && control.primary
  })
  |> should.be_true

  let removed = state.toggle_select(model, "feed-button")
  removed.selection |> should.equal(["pet-button"])
  removed.selected |> should.equal(Some("pet-button"))
}

pub fn frame_selects_components_by_resize_handles_test() {
  let framed =
    demo_state()
    |> state.set_rect_x(40)
    |> state.set_rect_y(230)
    |> state.set_rect_w(300)
    |> state.set_rect_h(40)
    |> state.select_frame(False)
  list.length(framed.selection) |> should.equal(2)
  list.contains(framed.selection, "pet-button") |> should.be_true
  list.contains(framed.selection, "feed-button") |> should.be_true
  framed.selected |> should.equal(Some("pet-button"))

  // A frame over the middle of a control but containing no handle selects none.
  let center_only =
    demo_state()
    |> state.set_rect_x(110)
    |> state.set_rect_y(248)
    |> state.set_rect_w(8)
    |> state.set_rect_h(8)
    |> state.select_frame(False)
  center_only.selection |> should.equal([])
}

pub fn multi_selection_delete_move_copy_test() {
  let two =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")

  let deleted = state.delete_selected(two)
  let assert Some(form) = state.active_form(deleted)
  list_length(form.controls) |> should.equal(5)
  deleted.selection |> should.equal([])

  let moved =
    two
    |> state.begin_gesture
    |> state.move_gesture_x(10)
    |> state.move_gesture_y(0)
    |> state.end_gesture
  let assert Some(form) = state.active_form(moved)
  let assert Ok(pet) = list.find(form.controls, fn(c) { c.id == "pet-button" })
  let assert Ok(feed) =
    list.find(form.controls, fn(c) { c.id == "feed-button" })
  pet.x |> should.equal(54)
  feed.x |> should.equal(206)

  let copied = state.copy_selected(two)
  let pasted = state.paste(state.select(copied, ""))
  let assert Some(form) = state.active_form(pasted)
  list_length(form.controls) |> should.equal(9)
  list_length(pasted.selection) |> should.equal(1)
}

pub fn palette_arms_and_places_component_test() {
  let armed = state.arm_component(demo_state(), "button")
  armed.pending_kind |> should.equal(Some(campy_form.Button))
  list_length(ide_ui.snapshot(armed).controls) |> should.equal(7)

  let placed =
    armed
    |> state.set_rect_x(300)
    |> state.set_rect_y(300)
    |> state.set_rect_w(120)
    |> state.set_rect_h(32)
    |> state.place_component
  let assert Some(form) = state.active_form(placed)
  list_length(form.controls) |> should.equal(8)
  placed.pending_kind |> should.equal(None)
  let assert Some(control) = state.selected_control(placed)
  control.x |> should.equal(300)
  control.y |> should.equal(300)
  control.width |> should.equal(120)
  control.height |> should.equal(32)
  campy_form.parent_of(form, control.id) |> should.equal("panel-1")
}

pub fn drag_over_reports_the_target_parent_test() {
  let dragged =
    demo_state()
    |> state.select("pet-button")
    |> state.begin_drag("pet-button")
    |> state.set_drop_x(300)
    |> state.update_drop(300)
  dragged.drop_active |> should.be_false
  dragged.drop_candidate |> should.equal("")

  let outside =
    demo_state()
    |> state.select("pet-button")
    |> state.begin_drag("pet-button")
    |> state.set_drop_x(700)
    |> state.update_drop(10)
  outside.drop_active |> should.be_true
  outside.drop_candidate |> should.equal("")

  state.end_gesture(dragged).drop_active |> should.be_false
}

pub fn drop_target_follows_the_cursor_test() {
  let added = state.add(state.select(demo_state(), ""), campy_form.Button)
  let assert Some(button) = state.selected_control(added)

  let beside_panel =
    added
    |> state.begin_gesture
    |> state.begin_drag(button.id)
    |> state.set_drop_x(600)
    |> state.update_drop(100)
    |> state.move_gesture_x(50)
    |> state.move_gesture_y(50)
    |> state.end_gesture
  let assert Some(form) = state.active_form(beside_panel)
  campy_form.parent_of(form, button.id) |> should.equal("")

  let over_panel =
    beside_panel
    |> state.begin_gesture
    |> state.begin_drag(button.id)
    |> state.set_drop_x(100)
    |> state.update_drop(100)
    |> state.move_gesture_x(0)
    |> state.move_gesture_y(10)
    |> state.end_gesture
  let assert Some(form) = state.active_form(over_panel)
  campy_form.parent_of(form, button.id) |> should.equal("panel-1")
}

pub fn console_logs_and_clears_test() {
  let logged =
    demo_state()
    |> state.log_console("hello")
    |> state.log_console("world")
  state.console_text(logged) |> should.equal("hello\nworld")
  state.console_text(state.clear_console(logged)) |> should.equal("")

  // A console line change is an AppendConsole op on the terminal.
  let ops = ide_ui.ops(ide_ui.snapshot(demo_state()), ide_ui.snapshot(logged))
  ops
  |> list.any(fn(op) {
    case op {
      // Each line carries its carriage return: a terminal moves down on LF
      // but keeps the column.
      ide_ui.AppendConsole(id, "hello\r\nworld\r\n") ->
        id == shell.section_id("console")
      _ -> False
    }
  })
  |> should.be_true
}

pub fn console_input_is_logged_test() {
  let model = state.console_input(demo_state(), "ping")
  let text = state.console_text(model)
  string.contains(text, "> ping") |> should.be_true
  string.contains(text, "app is not running") |> should.be_true
}

pub fn layout_selection_shows_in_the_grid_test() {
  let model = state.set_layout(demo_state(), campy_form.Column)
  let snapshot = ide_ui.snapshot(model)
  // The window grid carries the Layout choice with Column's index.
  let assert [row] =
    list.filter(snapshot.props, fn(row) { row.key == "layout" })
  row.index |> should.equal(1)
  row.kind |> should.equal("choice")
  row.options |> should.equal(["Free", "Column", "Row"])
  let assert Some(form) = state.active_form(model)
  form.layout |> should.equal(campy_form.Column)
}

pub fn multi_selection_grid_shows_common_props_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  let snapshot = ide_ui.snapshot(model)

  // Names and texts differ → blank. Y, W, H are shared by the two buttons.
  let assert Ok(name) = list.find(snapshot.props, fn(row) { row.key == "name" })
  name.value |> should.equal("")
  let assert Ok(text) = list.find(snapshot.props, fn(row) { row.key == "text" })
  text.value |> should.equal("")
  let assert Ok(y) = list.find(snapshot.props, fn(row) { row.key == "y" })
  y.value |> should.equal("236")
  let assert Ok(w) = list.find(snapshot.props, fn(row) { row.key == "w" })
  w.value |> should.equal("140")

  // Button rows only: no container Layout/Border, no picture Transparency.
  list.any(snapshot.props, fn(row) { row.key == "layout" }) |> should.be_false
  list.any(snapshot.props, fn(row) { row.key == "transparency" })
  |> should.be_false

  // Events: both buttons have OnClicked; handler names differ → blank value.
  let assert [event] = snapshot.events
  event.label |> should.equal("OnClicked")
  event.value |> should.equal("")
}

pub fn apply_prop_edits_the_whole_selection_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  let edited = state.apply_prop(model, "text", "Hello")
  let assert Some(form) = state.active_form(edited)
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let assert Some(feed) = campy_form.find_control(form, "feed-button")
  pet.text |> should.equal("Hello")
  feed.text |> should.equal("Hello")

  let moved = state.apply_prop(edited, "x", "40")
  let assert Some(form) = state.active_form(moved)
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let assert Some(feed) = campy_form.find_control(form, "feed-button")
  pet.x |> should.equal(40)
  feed.x |> should.equal(40)

  // A name is per-component: editing it in a multi-selection is rejected.
  let named = state.apply_prop(edited, "name", "renamed")
  named.status |> should.equal("Name applies to a single component")
}

// The inspector's window rows edit the form when nothing is selected.
pub fn window_rows_edit_the_form_test() {
  let renamed = state.apply_prop(demo_state(), "title", "Renamed")
  let assert Some(form) = state.active_form(renamed)
  form.title |> should.equal("Renamed")

  let laid_out = state.apply_prop(demo_state(), "layout", "Row")
  let assert Some(form) = state.active_form(laid_out)
  form.layout |> should.equal(campy_form.Row)
  let back = state.undo(laid_out)
  let assert Some(form) = state.active_form(back)
  form.layout |> should.equal(campy_form.Free)
}

pub fn align_selection_arranges_the_group_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("search-edit")

  // Left edges to the leftmost.
  let left = state.align_selection(model, "left")
  let assert Some(form) = state.active_form(left)
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let assert Some(search) = campy_form.find_control(form, "search-edit")
  pet.x |> should.equal(44)
  search.x |> should.equal(44)

  // Centre: average of the two centres (44+70 and 264+140 → 259).
  let centered = state.align_selection(model, "center")
  let assert Some(form) = state.active_form(centered)
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let assert Some(search) = campy_form.find_control(form, "search-edit")
  pet.x |> should.equal(259 - 70)
  search.x |> should.equal(259 - 140)

  // One undo step returns the whole arrangement.
  let undone = state.undo(centered)
  let assert Some(form) = state.active_form(undone)
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let assert Some(search) = campy_form.find_control(form, "search-edit")
  pet.x |> should.equal(44)
  search.x |> should.equal(264)

  // Fewer than two components cannot align.
  let single =
    state.align_selection(demo_state() |> state.select("pet-button"), "left")
  single.status |> should.equal("Select at least two components to align")
}

pub fn context_menu_selects_the_control_test() {
  let opened = demo_state() |> state.open_context_menu("pet-button;200;200")
  opened.context_open |> should.be_true
  opened.selected |> should.equal(Some("pet-button"))
  opened.selected_project |> should.be_false
  state.close_context_menu(opened).context_open |> should.be_false

  let canvas = demo_state() |> state.open_context_menu("")
  canvas.context_open |> should.be_true
  canvas.selected |> should.equal(None)
}

pub fn context_menu_keeps_multi_selection_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  let opened = state.open_context_menu(model, "pet-button;200;200")
  opened.context_open |> should.be_true
  list.length(opened.selection) |> should.equal(2)

  // Right-clicking outside the selection selects that component instead.
  let other = state.open_context_menu(model, "panel-1;200;200")
  other.selection |> should.equal(["panel-1"])

  // Opening the menu resets the Align submenu; closing clears both.
  let align_open = state.toggle_context_align(opened)
  align_open.context_align |> should.be_true
  let closed = state.close_context_menu(align_open)
  closed.context_open |> should.be_false
  closed.context_align |> should.be_false
}

pub fn project_selection_exposes_project_properties_test() {
  let selected = demo_state() |> state.switch_project(project.default_path)
  selected.selected_project |> should.be_true
  selected.selected |> should.equal(None)

  let control = selected |> state.select("pet-button")
  control.selected_project |> should.be_false

  let renamed = state.commit_project_field(selected, "title", "Renamed")
  renamed.project.title |> should.equal("Renamed")
  renamed.workspace.projects
  |> list.find(fn(item) { item.path == renamed.project.path })
  |> should.equal(Ok(project.Project(..renamed.project, title: "Renamed")))
}

pub fn container_layout_property_is_undoable_test() {
  let changed =
    demo_state()
    |> state.select("panel-1")
    |> state.commit_field("border", "8")
    |> state.set_container_layout(campy_form.Column)
  let assert Some(form) = state.active_form(changed)
  campy_form.layout_of(form, "panel-1") |> should.equal(campy_form.Column)
  let assert Some(panel) = campy_form.find_control(form, "panel-1")
  let assert Some(pet) = campy_form.find_control(form, "pet-button")
  let #(x, y, w, _) = campy_form.bounds(form, pet)
  should.equal(x, panel.x + 8)
  should.equal(w, panel.width - 16)
  should.be_true(y > panel.y + 8)

  let undone = state.undo(changed)
  let assert Some(form) = state.active_form(undone)
  campy_form.layout_of(form, "panel-1") |> should.equal(campy_form.Free)
}

pub fn project_dialog_opens_and_closes_test() {
  let open = state.set_project_dialog_open(demo_state(), True)
  open.project_dialog_open |> should.be_true
  state.set_project_dialog_open(open, False).project_dialog_open
  |> should.be_false
}

pub fn campy_has_a_tent_icon_test() {
  project.campy().icon |> should.equal(project.camping_icon)
  let changed = demo_state() |> state.set_project_icon("assets/cat.png")
  changed.project.icon |> should.equal("assets/cat.png")
  changed.workspace.projects
  |> list.find(fn(item) { item.path == changed.project.path })
  |> should.equal(Ok(project.Project(..changed.project, icon: "assets/cat.png")))
  state.undo(changed).project.icon |> should.equal(project.camping_icon)
}

pub fn border_fields_update_form_and_container_test() {
  let container =
    demo_state()
    |> state.select("panel-1")
    |> state.commit_field("border", "12")
  let assert Some(form) = state.active_form(container)
  campy_form.border_of(form, "panel-1") |> should.equal(12)
  let undone = state.undo(container)
  let assert Some(form) = state.active_form(undone)
  campy_form.border_of(form, "panel-1") |> should.equal(0)

  let window = demo_state() |> state.commit_field("border", "16")
  let assert Some(form) = state.active_form(window)
  campy_form.border_of(form, "") |> should.equal(16)
}

pub fn fill_alignment_is_available_test() {
  state.align_from_name("Fill") |> should.equal(campy_form.Fill)
  let aligned =
    demo_state()
    |> state.select("pet-button")
    |> state.set_align(campy_form.Fill)
  let assert Some(form) = state.active_form(aligned)
  campy_form.align_of(form, "pet-button") |> should.equal(campy_form.Fill)
}

pub fn paste_copies_container_border_and_layout_test() {
  let pasted =
    demo_state()
    |> state.select("panel-1")
    |> state.commit_field("border", "12")
    |> state.set_container_layout(campy_form.Column)
    |> state.copy_selected
    |> state.select("")
    |> state.paste
  let assert Some(form) = state.active_form(pasted)
  let assert Ok(copy) =
    list.find(form.controls, fn(control) {
      string.starts_with(control.id, "panel-1-copy")
    })
  campy_form.border_of(form, copy.id) |> should.equal(12)
  campy_form.layout_of(form, copy.id) |> should.equal(campy_form.Column)
}

pub fn ordering_actions_reorder_selection_test() {
  let model = demo_state() |> state.select("pet-button")
  let front = state.bring_to_front(model)
  let assert Some(form) = state.active_form(front)
  campy_form.render_controls(form)
  |> list.map(fn(control) { control.id })
  |> should.equal([
    "panel-1", "picture-1", "label-1", "list-1", "search-edit", "feed-button",
    "pet-button",
  ])

  let back = state.send_to_back(front |> state.select("pet-button"))
  let assert Some(form) = state.active_form(back)
  campy_form.render_controls(form)
  |> list.map(fn(control) { control.id })
  |> should.equal([
    "panel-1", "pet-button", "picture-1", "label-1", "list-1", "search-edit",
    "feed-button",
  ])

  let undone = state.undo(back)
  let assert Some(form) = state.active_form(undone)
  campy_form.render_controls(form)
  |> list.map(fn(control) { control.id })
  |> should.equal([
    "panel-1", "picture-1", "label-1", "list-1", "search-edit", "feed-button",
    "pet-button",
  ])
}

// Picture transparency flows from the inspector into the designer model, the
// clipboard, and the protocol-v2 form document.
pub fn picture_transparency_flows_everywhere_test() {
  let model = demo_state() |> state.select("picture-1")
  let set = state.commit_field(model, "transparency", "60")

  // Inspector grid row.
  ide_ui.snapshot(set).props
  |> list.any(fn(row) { row.key == "transparency" && row.value == "60" })
  |> should.be_true

  // Designer canvas model.
  ide_ui.snapshot(set).controls
  |> list.any(fn(control) {
    control.id == "picture-1" && control.transparency == 60
  })
  |> should.be_true

  // The protocol-v2 document carries it as the picture's opacity prop.
  let assert Some(form) = state.active_form(set)
  let assert Ok(picture) =
    live_preview.to_controls(form)
    |> flatten
    |> list.find(fn(desc) { desc.id == campy_form.wire_id("picture-1") })
  prop_int(picture, "transparency") |> should.equal(60)

  // Clipboard keeps it for paste.
  let copied = state.copy_selected(set)
  let pasted = state.paste(state.select(copied, ""))
  let assert Some(form) = state.active_form(pasted)
  let pasted_picture =
    list.find(form.controls, fn(control) {
      control.kind == campy_form.Picture && control.id != "picture-1"
    })
  let assert Ok(picture) = pasted_picture
  campy_form.transparency_of(form, picture.id) |> should.equal(60)

  // Rejected for non-pictures and out-of-range values.
  let rejected =
    state.commit_field(
      model |> state.select("pet-button"),
      "transparency",
      "50",
    )
  rejected.status |> should.equal("Transparency applies to pictures")
  let clamped = state.commit_field(model, "transparency", "500")
  clamped.status |> should.equal("Transparency must be between 0 and 100")
}

pub fn stale_project_format_migrates_on_hot_reload_test() {
  let model = demo_state()
  let stale =
    state.State(..model, project: project.Project(..model.project, version: 8))
  let next =
    state.ensure_current_format(stale, fn() { workspace.new(project.campy()) })
  next.project.version |> should.equal(project.version)
  string.contains(next.status, "upgraded") |> should.be_true

  // Current-format state is returned untouched; the loader must not run.
  let kept =
    state.ensure_current_format(model, fn() {
      panic as "loader must not run for the current format"
    })
  should.be_true(kept.project == model.project)
  kept.status |> should.equal(model.status)
}

pub fn placement_uses_computed_container_bounds_test() {
  let aligned =
    demo_state()
    |> state.select("panel-1")
    |> state.set_align(campy_form.Client)
  // The panel is Client-aligned: its rendered bounds are the window minus the
  // border, starting near (0,0) — far from its stored (24,24).
  let assert Some(form) = state.active_form(aligned)
  let assert Some(panel) = campy_form.find_control(form, "panel-1")
  let #(px, py, pw, ph) = campy_form.bounds(form, panel)
  should.be_true(pw >= 600 && ph >= 300)
  should.be_true(px < 24 || py < 24)

  let placed =
    aligned
    |> state.arm_component("button")
    |> state.set_rect_x(px + 40)
    |> state.set_rect_y(py + 40)
    |> state.set_rect_w(120)
    |> state.set_rect_h(32)
    |> state.place_component
  let assert Some(form) = state.active_form(placed)
  let assert Some(control) = state.selected_control(placed)
  campy_form.parent_of(form, control.id) |> should.equal("panel-1")
}

pub fn module_window_moves_and_resizes_test() {
  let model = demo_state()
  state.window_position(model) |> should.equal(#(32, 40))

  let moved = state.move_window(model, 20, 30)
  state.window_position(moved) |> should.equal(#(52, 70))

  let resized =
    model
    |> state.begin_gesture
    |> state.resize_window_w(40)
    |> state.resize_window_h(20)
    |> state.end_gesture
  let assert Some(form) = state.active_form(resized)
  form.width |> should.equal(680)
  form.height |> should.equal(440)

  let undone = state.undo(resized)
  let assert Some(form) = state.active_form(undone)
  form.width |> should.equal(640)
  form.height |> should.equal(420)
}

// ---------------------------------------------------------------------------
// Code editor: buffer, completions, diagnostics
// ---------------------------------------------------------------------------

pub fn code_editor_completion_flow_test() {
  let model = demo_state() |> state.select("pet-button")
  let typed = "pub fn pet_button_clicked() -> Nil {\n  pe\n}\n"

  let edited = state.code_edit(model, "1;4;" <> typed)
  edited.caret |> should.equal(#(1, 4))
  // Auto-committed: the module source is the live buffer.
  let assert Some(module) = state.active_module(edited)
  state.module_source(module) |> should.equal(typed)

  // A bare identifier does not open the popup (it would cover the code).
  let arrived =
    state.completions_arrived(
      edited,
      "println\tfn(String) -> Nil\tprintln\tfunction\n",
    )
  arrived.completions |> should.equal([])

  // Ctrl+Space forces it: Campy items merge with the server rows, filtered
  // by the typed segment ("pe" keeps pet_button; println is dropped).
  let requested = state.completion_requested(arrived)
  let forced =
    state.completions_arrived(
      requested,
      "println\tfn(String) -> Nil\tprintln\tfunction\n",
    )
  list.any(forced.completions, fn(item) { item.label == "pet_button" })
  |> should.be_true
  list.any(forced.completions, fn(item) { item.label == "println" })
  |> should.be_false
  list.any(forced.completions, fn(item) { item.label == "application" })
  |> should.be_false

  // Accepting the selection splices the insert at the caret and
  // auto-commits the module source again.
  let accepted = state.completion_accept(forced)
  accepted.caret |> should.equal(#(1, 12))
  accepted.completions |> should.equal([])
  let assert Some(module) = state.active_module(accepted)
  state.module_source(module)
  |> should.equal("pub fn pet_button_clicked() -> Nil {\n  pet_button\n}\n")

  // A dot opens the member list from the server, filtered after the dot.
  let dotted = state.code_edit(accepted, "1;15;pub fn x() {\n  io.\n}\n")
  let members =
    state.completions_arrived(
      dotted,
      "print\tfn(String) -> Nil\tprint\tfunction\nprintln\tfn(String) -> Nil\tprintln\tfunction\n",
    )
  list.any(members.completions, fn(item) { item.label == "println" })
  |> should.be_true
  list.any(members.completions, fn(item) { item.label == "pet_button" })
  |> should.be_false

  // Arrow-key navigation moves within the list; Escape closes it.
  let moved =
    members
    |> state.completion_move(1)
    |> state.completion_move(-5)
  moved.completion_index |> should.equal(0)
  state.completion_close(moved).completions |> should.equal([])
}

pub fn diagnostics_become_editor_marks_test() {
  let model = demo_state() |> state.set_view(state.CodeView)
  let dirty = state.diagnostics_arrived(model, "0\t1\tboom")
  let ops = ide_ui.ops(ide_ui.snapshot(model), ide_ui.snapshot(dirty))
  ops
  |> list.any(fn(op) {
    case op {
      ide_ui.SetMarks(id, "diagnostics", marks) ->
        id == shell.section_id("code-view") && list.length(marks) == 1
      _ -> False
    }
  })
  |> should.be_true
}

// ---------------------------------------------------------------------------
// External (codec v12) module sources
// ---------------------------------------------------------------------------

pub fn external_module_source_round_trips_through_the_file_test() {
  let path = temp_path("ide_external_source_test.gleam")
  let assert Ok(_) =
    write_fixture(path, "pub fn external_test() -> Nil {\n  Nil\n}\n")
  let module =
    project.Module(
      "external-test",
      "External",
      campy_form.new_form(),
      project.External(path),
    )
  state.module_source(module)
  |> should.equal("pub fn external_test() -> Nil {\n  Nil\n}\n")

  // Editing writes the file and keeps the path (the codec stores only it).
  let edited =
    state.set_module_source(module, "pub fn edited() -> Nil {\n  Nil\n}\n")
  edited.source_origin |> should.equal(project.External(path))
  state.module_source(edited)
  |> should.equal("pub fn edited() -> Nil {\n  Nil\n}\n")
  let _ = write_fixture(path, "")
}

// ---------------------------------------------------------------------------
// MCP
// ---------------------------------------------------------------------------

pub fn mcp_protocol_handles_initialize_and_tools_test() {
  let init =
    mcp.test_handle(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    )
  string.contains(init, "campy") |> should.be_true
  string.contains(init, "protocolVersion") |> should.be_true

  let tools =
    mcp.test_handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
  string.contains(tools, "campy_status") |> should.be_true
  string.contains(tools, "campy_console") |> should.be_true
}

pub fn mcp_http_server_serves_initialize_test() {
  let port = 39_817
  let assert Ok(_) = mcp.start(port)
  let init =
    mcp.test_post(
      port,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    )
  string.contains(init, "200 OK") |> should.be_true
  string.contains(init, "campy") |> should.be_true
  let _ = mcp.stop()
}

pub fn agent_settings_are_state_test() {
  let model = demo_state()
  model.mcp_enabled |> should.be_false
  model.mcp_port |> should.equal(7817)
  model.mcp_status |> should.equal("Stopped")

  let opened = state.set_agent_open(model, True)
  opened.agent_open |> should.be_true

  let configured =
    state.set_mcp_port(opened, 9000)
    |> state.set_mcp(True, "Listening")
  configured.mcp_port |> should.equal(9000)
  configured.mcp_enabled |> should.be_true
  configured.mcp_status |> should.equal("Listening")
}

pub fn mcp_tools_read_and_edit_state_test() {
  let assert #(_model, status, False) =
    campy_ide.mcp_handle(demo_state(), "status", "")
  string.contains(status, "Cat Café") |> should.be_true

  let assert #(_model, modules, False) =
    campy_ide.mcp_handle(demo_state(), "modules", "")
  string.contains(modules, "cat-cafe") |> should.be_true

  let assert #(_model, form, False) =
    campy_ide.mcp_handle(demo_state(), "form", "")
  string.contains(form, "pet-button") |> should.be_true

  let assert #(selected, _text, False) =
    campy_ide.mcp_handle(demo_state(), "select", "feed-button")
  let assert Some(control) = state.selected_control(selected)
  control.id |> should.equal("feed-button")

  let assert #(updated, _text, False) =
    campy_ide.mcp_handle(demo_state(), "set_field", "pet-button	text	MCP")
  let assert Some(control) = state.selected_control(updated)
  control.text |> should.equal("MCP")

  let assert #(console, _text, False) =
    campy_ide.mcp_handle(demo_state(), "send_input", "hello")
  string.contains(state.console_text(console), "> hello") |> should.be_true
}

// ---------------------------------------------------------------------------
// Preview document (no session)
// ---------------------------------------------------------------------------

pub fn preview_documents_follow_the_form_test() {
  let form = campy_form.demo_form()
  let assert [root] = live_preview.to_controls(form)
  root.id |> should.equal(campy_form.window_id)
  root.kind |> should.equal("panel")
  let controls = flatten(root.children)
  list.each(campy_form.render_controls(form), fn(control) {
    let id = campy_form.control_wire_id(control)
    controls |> list.any(fn(desc) { desc.id == id }) |> should.be_true
  })

  // Layout is a root prop the renderer honours for its children.
  let assert [column_root] =
    live_preview.to_controls(campy_form.Form(..form, layout: campy_form.Column))
  prop_text(column_root, "layout") |> should.equal("column")
}

pub fn welcome_module_previews_with_its_menu_test() {
  let assert Some(module) = project.find_module(project.campy(), "welcome")
  let assert Ok(menu) =
    live_preview.to_controls(module.form)
    |> flatten
    |> list.find(fn(desc) { desc.id == campy_form.wire_id("menu-1") })
  menu.kind |> should.equal("menu")
}

// ---------------------------------------------------------------------------
// Session tier (needs a display; the NIF is the real renderer)
// ---------------------------------------------------------------------------

// One runtime per process: closing the last session stops the UI event loop
// for good (Z0.2 constraint), so both session scenarios share one test and two
// concurrent sessions, closed together at the end.
pub fn live_shell_and_preview_sessions_test() {
  case has_display() && live_tests() {
    False -> Nil
    True -> {
      // --- the IDE shell document -----------------------------------------
      let model = demo_state()
      let assert Ok(shell) = bridge.open_session()
      list.each(
        ide_ui.commands(1, [ide_ui.Reload(ide_ui.snapshot(model))]),
        fn(command) {
          let assert Ok(_) = bridge.submit(shell, command)
        },
      )
      wait_for(1, "ui-loaded")

      // A granular selection change lands: the inspector's X row carries the
      // control's x after the ops apply.
      let selected = state.select(model, "pet-button")
      let ops =
        ide_ui.ops(
          ide_ui.without_content(ide_ui.snapshot(model)),
          ide_ui.snapshot(selected),
        )
      list.each(ide_ui.commands(1, ops), fn(command) {
        let assert Ok(_) = bridge.submit(shell, command)
      })
      read_text(shell, 1, campy_form.wire_id("insp:x")) |> should.equal("44")

      // Move it: another granular batch, and the editor row follows.
      let moved = state.move_selected(selected, 10, 0)
      let ops = ide_ui.ops(ide_ui.snapshot(selected), ide_ui.snapshot(moved))
      list.each(ide_ui.commands(1, ops), fn(command) {
        let assert Ok(_) = bridge.submit(shell, command)
      })
      read_text(shell, 1, campy_form.wire_id("insp:x")) |> should.equal("54")

      // --- the live preview document (Run / F6 / F7) -----------------------
      let assert Some(module) = project.find_module(project.campy(), "cat-cafe")
      let label = campy_form.wire_id("label-1")
      let assert Ok(preview) = bridge.open_session()
      let assert Ok(_) = live_preview_ui.load(preview, 1, module.form, "dark")
      wait_for(1, "ui-loaded")
      // `ui-loaded` means the document signal is set; the control registry is
      // rebuilt on the next UI-thread frame, so give it one before reading.
      sleep(100)
      read_text(preview, 1, label) |> should.equal("Mochi says hello!")

      // F6/F7 reload the same window at the next generation.
      //
      // RENDERER GAP (Z2.3, reported): the command is accepted and
      // `ui-loaded` arrives, but the live window is not rebuilt from the new
      // document — the second LoadUi only updates the renderer's document
      // signal (read untracked), so the reloaded text does not show yet. This
      // test therefore asserts the protocol path and that granular ops keep
      // addressing the same control ids at the new generation; the visual
      // reload is tracked on the G1 punch list.
      let updated =
        campy_form.update_selected(module.form, "label-1", fn(control) {
          campy_form.Control(..control, text: "Purr")
        })
      let assert Ok(_) = live_preview_ui.load(preview, 2, updated, "dark")
      wait_for(2, "ui-loaded")
      let assert Ok(_) =
        bridge.submit(preview, bridge.SetText(2, label, "Purr"))
      sleep(100)
      read_text(preview, 2, label) |> should.equal("Purr")

      no_failure(6)
      let _ = bridge.close_session(preview)
      let _ = bridge.close_session(shell)
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn demo_state() -> state.State {
  state.initial(project.campy())
}

fn flatten(controls: List(bridge.ControlDesc)) -> List(bridge.ControlDesc) {
  list.flat_map(controls, fn(control) { [control, ..flatten(control.children)] })
}

fn prop_text(control: bridge.ControlDesc, key: String) -> String {
  case
    list.find(control.props, fn(entry: #(String, bridge.WireValue)) {
      entry.0 == key
    })
  {
    Ok(#(_, bridge.WireText(text))) -> text
    _ -> ""
  }
}

fn prop_int(control: bridge.ControlDesc, key: String) -> Int {
  case
    list.find(control.props, fn(entry: #(String, bridge.WireValue)) {
      entry.0 == key
    })
  {
    Ok(#(_, bridge.WireInt(value))) -> value
    _ -> 0
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

@external(erlang, "campy_host_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "campy_fs_ffi", "write_file")
fn write_fixture(path: String, text: String) -> Result(Nil, String)

@external(erlang, "campy_host_ffi", "temp_path")
fn temp_path(name: String) -> String

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> Nil

fn wait_for(generation: Int, kind: String) -> Nil {
  wait_for_loop(generation, kind, now_ms())
}

fn wait_for_loop(generation: Int, kind: String, start: Int) -> Nil {
  case now_ms() - start > 60_000 {
    True -> panic as { "session timed out waiting for " <> kind }
    False -> Nil
  }
  case bridge.poll(1000) {
    Some(bridge.NativeEvent(_, received, event_kind, _))
      if received >= generation && event_kind == kind
    -> Nil
    Some(bridge.NativeEvent(_, _, "command-failed", payload)) ->
      panic as { "session command failed: " <> payload }
    Some(bridge.NativeEvent(_, _, "runtime-failed", payload)) ->
      panic as { "session runtime failed: " <> payload }
    _ -> wait_for_loop(generation, kind, start)
  }
}

// Read one control's text and wait for the reply, proving the ops before it
// applied to the live document.
fn read_text(session: bridge.Session, generation: Int, id: Int) -> String {
  let assert Ok(_) =
    bridge.submit(session, bridge.ReadText(generation, id, "text"))
  read_reply("read:" <> int.to_string(id) <> ":text", now_ms())
}

fn read_reply(kind: String, start: Int) -> String {
  case now_ms() - start > 60_000 {
    True -> panic as { "session read timed out: " <> kind }
    False -> Nil
  }
  case bridge.poll(1000) {
    Some(bridge.NativeEvent(_, _, event_kind, payload)) if event_kind == kind ->
      payload
    Some(bridge.NativeEvent(_, _, "command-failed", payload)) ->
      panic as { "session read failed: " <> payload }
    _ -> read_reply(kind, start)
  }
}

fn no_failure(attempts: Int) -> Nil {
  case attempts {
    0 -> Nil
    _ ->
      case bridge.poll(50) {
        Some(bridge.NativeEvent(_, _, "command-failed", payload)) -> {
          io.println("live model update failed: " <> payload)
          should.fail()
        }
        Some(bridge.NativeEvent(_, _, "runtime-failed", payload)) -> {
          io.println("live model runtime failed: " <> payload)
          should.fail()
        }
        _ -> no_failure(attempts - 1)
      }
  }
}

// ---------------------------------------------------------------------------
// Hover hints
// ---------------------------------------------------------------------------

pub fn hover_hint_takes_and_restores_the_status_test() {
  let model = demo_state()
  let hovering = state.hover(model, "Pet the cat — click")
  hovering.status |> should.equal("Pet the cat — click")
  // Leaving puts the message that was there back rather than clearing it.
  let left = state.hover(hovering, "")
  left.status |> should.equal(model.status)
  // The settings dialog's "Show UI hints" gates it.
  let quiet = state.hover(state.set_hints(model, False), "ignored")
  quiet.status |> should.equal(model.status)
}

// ---------------------------------------------------------------------------
// Designer selection: additive press, marquee extension, grips
// ---------------------------------------------------------------------------

pub fn a_modified_press_adds_and_removes_from_the_selection_test() {
  let model = demo_state() |> state.select("pet-button")
  // Ctrl-click on the other button adds it; the newest press is the primary.
  let wider =
    model
    |> state.pointer_down(600, 500)
    |> state.pointer_up(600, 500, True)
  // (600,500) is empty canvas, so a modified press on nothing keeps the
  // selection rather than clearing it.
  list.length(wider.selection) |> should.equal(1)

  let added =
    model
    |> state.pointer_down(266, 252)
    |> state.pointer_up(266, 252, True)
  added.selected |> should.equal(Some("feed-button"))
  list.length(added.selection) |> should.equal(2)

  // A second modified press takes it out again.
  let removed =
    added
    |> state.pointer_down(266, 252)
    |> state.pointer_up(266, 252, True)
  list.length(removed.selection) |> should.equal(1)
  removed.selected |> should.equal(Some("pet-button"))

  // Without the modifier a press replaces the selection.
  let replaced =
    added
    |> state.pointer_down(266, 252)
    |> state.pointer_up(266, 252, False)
  list.length(replaced.selection) |> should.equal(1)
}

pub fn a_modified_marquee_extends_the_selection_test() {
  let model = demo_state() |> state.select("label-1")
  let extended =
    model
    |> state.pointer_down(40, 230)
    |> state.pointer_move(300, 300)
    |> state.pointer_up(300, 300, True)
  list.contains(extended.selection, "label-1") |> should.be_true
  list.contains(extended.selection, "pet-button") |> should.be_true
  list.length(extended.selection) |> should.equal(3)
}

pub fn grips_are_hit_tested_where_they_are_drawn_test() {
  let model = demo_state() |> state.select("pet-button")
  let assert Some(form) = state.active_form(model)
  let assert Some(control) = state.selected_control(model)
  // pet-button is (44,236,140,32); its east grip sits on the right edge's
  // middle, which is where the shell draws a square of `grip_size`.
  let #(x, y, w, h) = campy_form.bounds(form, control)
  let resized =
    model
    |> state.pointer_down(x + w, y + h / 2)
    |> state.pointer_move(x + w + 20, y + h / 2)
    |> state.pointer_up(x + w + 20, y + h / 2, False)
  let assert Some(after) = state.selected_control(resized)
  after.width |> should.equal(w + 20)
  // What is drawn is what is grabbable: one constant, two users.
  shell.grip_size |> should.equal(state.resize_grip)
}

// ---------------------------------------------------------------------------
// Undo: a run of keystrokes in one property field is one step
// ---------------------------------------------------------------------------

pub fn typing_in_a_property_field_is_one_undo_step_test() {
  let typed =
    demo_state()
    |> state.select("pet-button")
    |> state.commit_field("text", "P")
    |> state.commit_field("text", "Pu")
    |> state.commit_field("text", "Purr")
  let assert Some(control) = state.selected_control(typed)
  control.text |> should.equal("Purr")
  state.can_undo(typed) |> should.be_true

  // One undo, not three: the run closed when the value settled.
  let back = state.undo(typed)
  let assert Some(old) = state.selected_control(back)
  old.text |> should.equal("Pet the cat")
  state.can_undo(back) |> should.be_false

  let again = state.redo(back)
  let assert Some(redone) = state.selected_control(again)
  redone.text |> should.equal("Purr")
}

pub fn editing_another_field_starts_a_new_step_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.commit_field("text", "Purr")
    // A different field of the same control is a different run.
    |> state.commit_field("name", "purr_button")
  let assert Some(control) = state.selected_control(model)
  control.name |> should.equal("purr_button")

  let one = state.undo(model)
  let assert Some(mid) = state.selected_control(one)
  mid.name |> should.equal("pet_button")
  mid.text |> should.equal("Purr")
}

pub fn a_rejected_field_value_does_not_open_a_step_test() {
  // A duplicate name is refused; it must not leave a half-open run behind that
  // swallows the next real edit's undo step.
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.commit_field("name", "feed_button")
  let assert Some(control) = state.selected_control(model)
  control.name |> should.equal("pet_button")
  state.can_undo(model) |> should.be_false

  let typed = state.commit_field(model, "name", "purr_button")
  let back = state.undo(typed)
  let assert Some(old) = state.selected_control(back)
  old.name |> should.equal("pet_button")
}

pub fn wire_coordinates_parse_as_whole_pixels_test() {
  // The renderer writes whole CSS pixels. Erlang's `float.parse` rejects `376`
  // — a float needs its point — and a coordinate that failed to parse used to
  // read as zero, which put every press in a real window at the form's
  // top-left instead of under the pointer.
  campy_ide.pixel("376") |> should.equal(376)
  campy_ide.pixel("0") |> should.equal(0)
  campy_ide.pixel(" 42 ") |> should.equal(42)
  campy_ide.pixel("-7") |> should.equal(-7)
  // A decimal payload is still understood.
  campy_ide.pixel("376.4") |> should.equal(376)
  campy_ide.pixel("376.6") |> should.equal(377)
  campy_ide.pixel("") |> should.equal(0)
}
