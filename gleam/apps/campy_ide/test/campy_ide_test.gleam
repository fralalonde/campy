import campy_bridge
import campy_form
import campy_form/live_preview
import campy_form/preview
import campy_form/project
import campy_ide
import campy_ide/ide_ui
import campy_ide/live_preview_ui
import campy_ide/mcp
import campy_ide/state
import campy_search_box
import campy_ui
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn search_box_compiles_through_the_real_bridge_test() {
  let assert Ok(source) =
    campy_ui.to_application_slint(campy_search_box.describe())
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn ide_shell_compiles_through_the_real_bridge_test() {
  let assert Ok(source) = ide_ui.to_slint(demo_state())
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn ide_code_view_and_handler_editor_compile_test() {
  let code = state.set_view(demo_state(), state.CodeView)
  let assert Ok(source) = ide_ui.to_slint(code)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
  let editing =
    code
    |> state.select("pet-button")
    |> state.open_event("clicked")
  let assert Ok(source) = ide_ui.to_slint(editing)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn ide_module_tabs_and_new_modules_compile_test() {
  let opened = state.open_module(demo_state(), "search-box")
  let assert Ok(source) = ide_ui.to_slint(opened)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
  let added = state.new_module(opened)
  let assert Ok(source) = ide_ui.to_slint(added)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
  let closed = state.close_module(added, added.active)
  let assert Ok(source) = ide_ui.to_slint(closed)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn ide_file_dialog_compiles_test() {
  let model = state.set_popup(demo_state(), state.OpenFile)
  let assert Ok(source) = ide_ui.to_slint(model)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

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

pub fn last_module_tab_cannot_close_test() {
  let closed = state.close_module(demo_state(), demo_state().active)
  closed.status |> should.equal("Cannot close the last tab")
}

pub fn form_preview_compiles_through_the_real_bridge_test() {
  let assert Ok(source) = preview.to_slint(campy_form.demo_form())
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn models_reflect_the_designer_test() {
  let model = demo_state()
  let snapshot = ide_ui.snapshot(model)
  list_length(snapshot.modules) |> should.equal(4)
  list_length(snapshot.tabs) |> should.equal(1)
  list_length(snapshot.controls) |> should.equal(7)
  let has_code = list_length(snapshot.code) > 0
  has_code |> should.be_true
}

pub fn structural_edits_change_models_not_the_shell_test() {
  let model = demo_state()

  let added = state.add(model, campy_form.Button)
  list_length(ide_ui.snapshot(added).controls) |> should.equal(8)

  let deleted = state.delete_selected(added)
  list_length(ide_ui.snapshot(deleted).controls) |> should.equal(7)

  let opened = state.open_module(model, "search-box")
  list_length(ide_ui.snapshot(opened).tabs) |> should.equal(2)
  ide_ui.snapshot(opened).controls
  |> list.any(fn(control) { control.text == "Search" })
  |> should.be_true

  // A new handler appends a stub, changing only the code model.
  let before = ide_ui.snapshot(model).code
  let stub =
    model
    |> state.select("search-edit")
    |> state.open_event("changed")
  let after = ide_ui.snapshot(stub).code
  after |> should.not_equal(before)

  // The shell is model-driven; its structural parts do not depend on the
  // edited state (only baked scalar defaults differ).
  let assert Ok(shell) = ide_ui.to_slint(model)
  string.contains(shell, "for module in root.module-items") |> should.be_true
  string.contains(shell, "for tab in root.tab-items") |> should.be_true
  string.contains(shell, "for control in root.control-items") |> should.be_true
  string.contains(shell, "for line in root.code-lines") |> should.be_true
}

pub fn selection_updates_control_model_and_scalars_test() {
  let model = demo_state()
  let snapshot = ide_ui.snapshot(model)
  let selected = state.select(model, "pet-button")
  let next = ide_ui.snapshot(selected)

  next.controls
  |> list.any(fn(control) { control.id == "pet-button" && control.selected })
  |> should.be_true

  let changes = ide_ui.diff(snapshot.scalars, next.scalars)
  ide_ui.diff(snapshot.scalars, snapshot.scalars) |> should.equal([])
  list.any(changes, fn(update) { ide_ui.update_name(update) == "has-selection" })
  |> should.be_true
  list.any(changes, fn(update) { ide_ui.update_name(update) == "insp-name" })
  |> should.be_true
  list.any(changes, fn(update) { ide_ui.update_name(update) == "status" })
  |> should.be_false
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

pub fn list_and_panel_components_render_test() {
  let with_components =
    demo_state()
    |> state.new_module()
    |> state.add(campy_form.ListBox)
    |> state.add(campy_form.Panel)
  let assert Ok(source) = ide_ui.to_slint(with_components)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
  let controls = ide_ui.snapshot(with_components).controls
  list.any(controls, fn(control) { control.kind == "list" })
  |> should.be_true
  list.any(controls, fn(control) { control.kind == "panel" })
  |> should.be_true
}

pub fn layout_modes_update_scalars_test() {
  let model = demo_state()
  let before = ide_ui.snapshot(model).scalars
  let after =
    ide_ui.snapshot(state.set_layout(model, campy_form.Column)).scalars
  let changes = ide_ui.diff(before, after)
  list.any(changes, fn(update) { ide_ui.update_name(update) == "layout-column" })
  |> should.be_true
}

pub fn preview_honours_form_layouts_test() {
  let form =
    campy_form.Form(
      "campy.form",
      "Demo",
      400,
      300,
      campy_form.Free,
      [
        campy_form.Control(
          "l-1",
          "label1",
          campy_form.Label,
          8,
          8,
          100,
          24,
          "Hi",
          True,
          True,
        ),
        campy_form.Control(
          "list-1",
          "list1",
          campy_form.ListBox,
          8,
          40,
          200,
          120,
          "",
          True,
          True,
        ),
        campy_form.Control(
          "panel-1",
          "panel1",
          campy_form.Panel,
          8,
          170,
          200,
          80,
          "Panel",
          True,
          True,
        ),
      ],
      [],
      [],
      [],
    )
  let assert Ok(free) = preview.to_slint(form)
  campy_bridge.validate_ui(free) |> should.equal(Ok(1))
  string.contains(free, "ListView") |> should.be_true

  let assert Ok(column) =
    preview.to_slint(campy_form.Form(..form, layout: campy_form.Column))
  campy_bridge.validate_ui(column) |> should.equal(Ok(1))
  string.contains(column, "VerticalLayout") |> should.be_true

  let assert Ok(row) =
    preview.to_slint(campy_form.Form(..form, layout: campy_form.Row))
  campy_bridge.validate_ui(row) |> should.equal(Ok(1))
  string.contains(row, "HorizontalLayout") |> should.be_true
}

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

pub fn settings_change_theme_colors_test() {
  let model = demo_state()
  let before = ide_ui.snapshot(model).scalars
  let after = ide_ui.snapshot(state.set_scheme(model, state.Light)).scalars
  let changes = ide_ui.diff(before, after)
  list.any(changes, fn(update) { ide_ui.update_name(update) == "theme-bg" })
  |> should.be_true
}

pub fn picture_control_carries_its_image_path_test() {
  let model = demo_state()
  let snapshot = ide_ui.snapshot(model)
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
    |> state.open_event("changed")
  let assert Some(module) = state.active_module(stubbed)
  string.contains(module.source, "search_edit_changed") |> should.be_true

  let restored = state.undo(stubbed)
  let assert Some(after) = state.active_module(restored)
  string.contains(after.source, "search_edit_changed") |> should.be_false
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

  let back = state.switch_project(created, "projects/campy.campy")
  back.project.title |> should.equal("Campy")
  list.length(back.project.modules) |> should.equal(4)

  let deleted = state.delete_active_project(back)
  list.length(deleted.workspace.projects) |> should.equal(1)
  deleted.project.title |> should.equal("Project 1")

  let blocked = state.delete_active_project(deleted)
  list.length(blocked.workspace.projects) |> should.equal(1)
}

pub fn widgets_preview_compiles_test() {
  let assert Some(widgets) = project.find_module(project.campy(), "widgets")
  let assert Ok(source) = preview.to_slint(widgets.form)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
}

pub fn live_preview_shell_and_snapshot_test() {
  campy_bridge.validate_ui(live_preview.to_slint()) |> should.equal(Ok(1))

  let assert Some(cat) = project.find_module(project.campy(), "cat-cafe")
  let snapshot = live_preview.snapshot(cat.form)
  snapshot.title |> should.equal("Cat Café")
  list.length(snapshot.controls) |> should.equal(7)
  let assert Ok(picture) =
    list.find(snapshot.controls, fn(control) { control.kind == "picture" })
  picture.picture |> should.equal("assets/cat.png")

  let assert Some(widgets) = project.find_module(project.campy(), "widgets")
  let snapshot = live_preview.snapshot(widgets.form)
  let assert Ok(header) =
    list.find(snapshot.controls, fn(control) { control.id == "header" })
  header.x |> should.equal(0)
  header.w |> should.equal(640)
  let assert Ok(footer) =
    list.find(snapshot.controls, fn(control) { control.id == "footer" })
  footer.y |> should.equal(436)
  let assert Ok(progress) =
    list.find(snapshot.controls, fn(control) { control.id == "progress-1" })
  progress.value |> should.equal(80)
  let assert Ok(slider) =
    list.find(snapshot.controls, fn(control) { control.id == "slider-1" })
  slider.value |> should.equal(70)
  list.length(live_preview_ui.wire(snapshot.controls)) |> should.equal(12)
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
  state.selected_control(model)
  |> should.equal(campy_form.find_control(
    {
      let assert Some(form) = state.active_form(model)
      form
    },
    "feed-button",
  ))
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
    |> state.select_frame
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
    |> state.select_frame
  center_only.selection |> should.equal([])
}

pub fn multi_selection_delete_move_copy_test() {
  let two =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")

  let deleted = state.delete_selected(two)
  let assert Some(form) = state.active_form(deleted)
  list.length(form.controls) |> should.equal(5)
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
  list.length(form.controls) |> should.equal(9)
  list.length(pasted.selection) |> should.equal(1)
}

pub fn palette_arms_and_drag_places_component_test() {
  let armed = state.arm_component(demo_state(), "button")
  armed.pending_kind |> should.equal(Some(campy_form.Button))
  list.length(ide_ui.snapshot(armed).controls) |> should.equal(7)

  let placed =
    armed
    |> state.set_rect_x(300)
    |> state.set_rect_y(300)
    |> state.set_rect_w(120)
    |> state.set_rect_h(32)
    |> state.place_component
  let assert Some(form) = state.active_form(placed)
  list.length(form.controls) |> should.equal(8)
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
    |> state.begin_drag
    |> state.set_drop_x(300)
    |> state.update_drop(300)
  dragged.drop_active |> should.be_false
  dragged.drop_candidate |> should.equal("")

  let outside =
    demo_state()
    |> state.select("pet-button")
    |> state.begin_drag
    |> state.set_drop_x(700)
    |> state.update_drop(10)
  outside.drop_active |> should.be_true
  outside.drop_candidate |> should.equal("")

  state.end_gesture(dragged).drop_active |> should.be_false
}

pub fn hints_toggle_is_a_scalar_test() {
  let model = demo_state()
  let off = state.set_hints(model, False)
  ide_ui.diff(ide_ui.snapshot(model).scalars, ide_ui.snapshot(off).scalars)
  |> list.any(fn(update) { ide_ui.update_name(update) == "show-hints" })
  |> should.be_true
}

pub fn shell_contains_ui_hints_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(shell, "if root.show-hints: Tooltip") |> should.be_true
  string.contains(shell, "Show UI hints") |> should.be_true
  string.contains(shell, "for item in root.palette-items")
  |> should.be_true
}

pub fn console_logs_and_clears_test() {
  let logged =
    demo_state()
    |> state.log_console("hello")
    |> state.log_console("world")
  state.console_text(logged) |> should.equal("hello\nworld")
  state.console_text(state.clear_console(logged)) |> should.equal("")
}

pub fn console_input_is_logged_test() {
  let model = state.console_input(demo_state(), "ping")
  let text = state.console_text(model)
  string.contains(text, "> ping") |> should.be_true
  string.contains(text, "app is not running") |> should.be_true
}

pub fn layout_selection_is_a_scalar_test() {
  let model = state.set_layout(demo_state(), campy_form.Column)
  let snapshot = ide_ui.snapshot(model)
  let assert Ok(update) =
    list.find(snapshot.scalars, fn(item) {
      ide_ui.update_name(item) == "layout-index"
    })
  update |> should.equal(ide_ui.ScalarIntUpdate("layout-index", 1))
  let assert Some(form) = state.active_form(model)
  form.layout |> should.equal(campy_form.Column)
}

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

pub fn module_window_moves_and_resizes_test() {
  let model = demo_state()
  state.window_position(model) |> should.equal(#(32, 120))

  let moved = state.move_window(model, 20, 30)
  state.window_position(moved) |> should.equal(#(52, 150))

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

// Models and scalars must apply to the live instance without a new LoadUi.
pub fn models_apply_on_the_live_instance_test() {
  let model = demo_state()
  let assert Ok(source) = ide_ui.to_slint(model)
  let assert Ok(session) = campy_bridge.open_session()
  let assert Ok(_) =
    campy_bridge.submit(session, campy_bridge.LoadUi(1, source))
  wait_for(1, "ui-loaded")

  let snapshot = ide_ui.snapshot(model)
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(
        1,
        "module-items",
        ide_ui.modules_wire(snapshot.modules),
      ),
    )
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(1, "tab-items", ide_ui.tabs_wire(snapshot.tabs)),
    )
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(
        1,
        "control-items",
        ide_ui.controls_wire(snapshot.controls),
      ),
    )
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(1, "code-lines", ide_ui.code_wire(snapshot.code)),
    )
  let assert Ok(_) =
    campy_bridge.submit(session, campy_bridge.ReadText(1, "status"))
  wait_property("status") |> should.equal(model.status)
  wait_no_failure(5)
  let _ = campy_bridge.close_session(session)
}

fn demo_state() -> state.State {
  state.initial(project.campy())
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn wait_for(generation: Int, kind: String) -> Nil {
  case campy_bridge.poll(1000) {
    Some(campy_bridge.NativeEvent(_, received, event_kind, _))
      if received >= generation && event_kind == kind
    -> Nil
    _ -> wait_for(generation, kind)
  }
}

fn wait_property(name: String) -> String {
  let wanted = "property:" <> name
  case campy_bridge.poll(1000) {
    Some(campy_bridge.NativeEvent(_, _, event_kind, payload))
      if event_kind == wanted
    -> payload
    _ -> wait_property(name)
  }
}

fn wait_no_failure(attempts: Int) -> Nil {
  case attempts {
    0 -> Nil
    _ ->
      case campy_bridge.poll(100) {
        Some(campy_bridge.NativeEvent(_, _, "command-failed", payload)) -> {
          io.println("live model update failed: " <> payload)
          should.fail()
        }
        Some(campy_bridge.NativeEvent(_, _, "runtime-failed", payload)) -> {
          io.println("live model runtime failed: " <> payload)
          should.fail()
        }
        _ -> wait_no_failure(attempts - 1)
      }
  }
}

pub fn menu_component_compiles_in_preview_test() {
  let assert Some(module) = project.find_module(project.campy(), "welcome")
  let assert Ok(source) = preview.to_slint(module.form)
  campy_bridge.validate_ui(source) |> should.equal(Ok(1))
  let live = live_preview.to_slint()
  campy_bridge.validate_ui(live) |> should.equal(Ok(1))
}

pub fn context_menu_selects_the_control_test() {
  let opened = demo_state() |> state.open_context_menu("pet-button")
  opened.context_open |> should.be_true
  opened.selected |> should.equal(Some("pet-button"))
  opened.selected_project |> should.be_false
  state.close_context_menu(opened).context_open |> should.be_false

  let canvas = demo_state() |> state.open_context_menu("")
  canvas.context_open |> should.be_true
  canvas.selected |> should.equal(None)
}

pub fn project_selection_exposes_project_properties_test() {
  let selected = demo_state() |> state.switch_project("projects/campy.campy")
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
