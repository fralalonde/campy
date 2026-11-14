import campy_bridge
import campy_form
import campy_form/live_preview
import campy_form/preview
import campy_form/project
import campy_form/workspace
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

// The navigator context menu's Delete removes a module from the project even
// when it is not the active tab; undo restores it.
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
  // edited state (only baked scalar defaults differ). Opened modules render
  // as tabs of the TabPanel, each closable.
  let assert Ok(shell) = ide_ui.to_slint(model)
  string.contains(shell, "for module[index] in root.module-items")
  |> should.be_true
  string.contains(shell, "TabPanel {") |> should.be_true
  string.contains(shell, "model: root.tab-items;") |> should.be_true
  string.contains(shell, "for tab in root.model:") |> should.be_true
  string.contains(shell, "select-tab(id) => { root.tab-module(id); }")
  |> should.be_true
  string.contains(shell, "close-tab(id) => { root.close-module(id); }")
  |> should.be_true
  string.contains(shell, "for control in root.control-items") |> should.be_true
  // The code pane is an editable transparent TextInput over the highlight
  // layer the renderer tokenizes natively.
  string.contains(shell, "code-input := TextInput {") |> should.be_true
  string.contains(shell, "text <=> root.code-text;") |> should.be_true
  string.contains(shell, "for line in root.code-lines: Rectangle")
  |> should.be_true
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
  // The property grid now carries the selected control's values.
  list.any(next.props, fn(row) {
    row.key == "name" && row.value == "pet_button"
  })
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
          [],
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
          [],
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
          [],
        ),
      ],
      [],
      [],
      [],
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
    |> state.open_event("edited")
  let assert Some(module) = state.active_module(stubbed)
  string.contains(module.source, "search_edit_edited") |> should.be_true

  let restored = state.undo(stubbed)
  let assert Some(after) = state.active_module(restored)
  string.contains(after.source, "search_edit_edited") |> should.be_false
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

// The cursor, not the dragged control's centre, decides the drop target: the
// button lands on panel-1 but the pointer stays beside it, so the window keeps
// it; releasing with the cursor over the panel adopts it.
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

// Palette hints are hover-state driven, not dwell-timer tooltips: Slint's
// Tooltip restarts its delay on every pointer move, so a human hand (which
// never holds perfectly still) never sees one. The palette instead shows a
// hint chip driven by has-hover, which jitter cannot reset.
pub fn palette_hints_are_hover_chips_not_dwell_tooltips_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  // No dwell tooltip on the palette tiles.
  string.contains(shell, "@markdown(\"{item.label}\")") |> should.be_false
  // Hovering a tile sets the hint text; leaving clears it (guarded so a
  // neighbouring tile's enter is not clobbered by this tile's exit).
  string.contains(
    shell,
    "if self.has-hover { root.palette-hint = item.label + \" — click, then drag on the form to place it\"; }",
  )
  |> should.be_true
  string.contains(
    shell,
    "if !self.has-hover && root.palette-hint == item.label + \" — click, then drag on the form to place it\" { root.palette-hint = \"\"; }",
  )
  |> should.be_true
  // The chip renders below the palette bar, only while a tile is hovered and
  // hints are enabled.
  string.contains(
    shell,
    "if root.palette-hint != \"\" && root.show-hints: Rectangle {",
  )
  |> should.be_true
}

// Each opened module is a proper tab: closable, selected through the panel.
pub fn tab_panel_renders_opened_modules_test() {
  let model = state.open_module(demo_state(), "widgets")
  let snapshot = ide_ui.snapshot(model)
  list_length(snapshot.tabs) |> should.equal(2)

  let assert Ok(shell) = ide_ui.to_slint(model)
  string.contains(shell, "component TabPanel inherits Rectangle")
  |> should.be_true
  // Tabs come from the model, so opening/closing modules never reloads.
  string.contains(shell, "for tab in root.model: Rectangle {")
  |> should.be_true
  string.contains(shell, "clicked => { root.select-tab(tab.id); }")
  |> should.be_true
  string.contains(shell, "clicked => { root.close-tab(tab.id); }")
  |> should.be_true
  // The module editor lives inside the panel's content area.
  string.contains(shell, "TabPanel {") |> should.be_true
  string.contains(
    shell,
    "Rectangle { horizontal-stretch: 1; vertical-stretch: 1;",
  )
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

// Shift is no longer a selection modifier: no property lights the window
// outline, and the plain select tool draws the marquee itself.
pub fn shell_has_no_shift_selection_modifier_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(shell, "shift-down") |> should.be_false
  string.contains(shell, "frame-tool") |> should.be_false
  // Pressing arms nothing; crossing the threshold arms the drag, and
  // selection and moves are still committed on release.
  string.contains(shell, "left) { root.gesture-start();")
  |> should.be_false
  string.contains(
    shell,
    "drag-armed = true; root.gesture-start(); root.drag-start(data.id);",
  )
  |> should.be_true
  string.contains(
    shell,
    "if (root.additive) { root.toggle-select(data.id); } else { root.select(data.id); }",
  )
  |> should.be_true
  // Drag-over reports the cursor position, not the control's centre.
  string.contains(shell, "round((data.x + self.mouse-x) / 1px)")
  |> should.be_true
}

// The hybrid gesture contract on a free-layout control: a press alone commits
// nothing; dragging past the threshold from a selected control moves it, while
// dragging from an unselected control draws the same dotted marquee as the
// empty canvas and commits it through the frame pipeline (so drag-to-select
// works even when the gesture starts on top of a component).
pub fn control_drag_beyond_threshold_draws_marquee_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  // Pressing a control starts neither the drag nor the frame.
  string.contains(shell, "left) { root.gesture-start();")
  |> should.be_false
  // Past the threshold, an unselected control opens the window-level marquee
  // at the press point (control-relative mouse plus the control's origin).
  string.contains(shell, "marquee-armed = true; marquee-active = true;")
  |> should.be_true
  string.contains(shell, "marquee-x = data.x + self.pressed-x;")
  |> should.be_true
  // The frame commits through the same rect/frame-apply pipeline as the
  // canvas marquee, with keyboard focus restored for follow-up commands.
  string.contains(shell, "root.rect-x(round(marquee-x / 1px));")
  |> should.be_true
  string.contains(shell, "root.rect-h(round(marquee-h / 1px));")
  |> should.be_true
  string.contains(
    shell,
    "frame-apply() => { key-handler.focus(); root.frame-apply(); }",
  )
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

// With several components selected the grid shows only the properties they
// have in common; values that differ are blank, shared values are shown.
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

// Editing a shared property applies to every selected component.
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

  // Geometry: both buttons take the same X.
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

// The context-menu Align submenu: edges to the shared extreme, centres to
// the average, each root moving with its subtree in one undo step.
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

// The shell: inspector text and canvas size are gone; the right pane is a
// two-tab grid; the editor views switch via the corner button and Ctrl+Tab;
// the multi-selection context menu carries the Align submenu.
pub fn shell_inspector_grid_and_view_toggle_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(shell, "\"Inspector\"") |> should.be_false
  string.contains(shell, "canvas-label") |> should.be_false
  string.contains(shell, "UI (actual)") |> should.be_false
  string.contains(shell, "Code (Slint file)") |> should.be_false
  string.contains(shell, "text: \"▦ Form\"") |> should.be_true
  string.contains(shell, "text: \"⌨ Raw\"") |> should.be_true
  // Tab strip with no buttons, and one grid for both tabs.
  string.contains(shell, "root.events-tab ? root.event-items : root.prop-items")
  |> should.be_true
  string.contains(shell, "component PropGrid inherits Rectangle")
  |> should.be_true
  string.contains(shell, "component PropRow inherits Rectangle")
  |> should.be_true
  // Corner view toggle with alternating pictogram, and its shortcut.
  string.contains(shell, "text: root.code-view ? \"▦\" : \"⌨\"")
  |> should.be_true
  string.contains(shell, "@keys(Control + Tab)") |> should.be_true
  string.contains(shell, "Form editor\" : \"⌨ Handler code\"")
  |> should.be_false
  // The Align submenu appears for multi-selections and dispatches each kind.
  string.contains(
    shell,
    "if root.selection-count > 1: MenuRow { label: \"Align ▸\"",
  )
  |> should.be_true
  string.contains(shell, "root.align-selection(\"middle\")") |> should.be_true
}

// The code pane: always an editable transparent TextInput over the
// tree-sitter highlight layer; no Apply/Discard buttons.
pub fn code_pane_always_editable_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(shell, "code-input := TextInput {") |> should.be_true
  string.contains(shell, "text <=> root.code-text;") |> should.be_true
  string.contains(shell, "root.code-apply(") |> should.be_false
  string.contains(shell, "code-source") |> should.be_false
  // Keystrokes stream to the tokenizer and language server.
  string.contains(
    shell,
    "root.code-edit(\"\\{code-caret-line};\\{code-caret-col};\" + self.text);",
  )
  |> should.be_true
  string.contains(shell, "for diag in root.diag-items: Rectangle")
  |> should.be_true
  // The completion popup anchors at the caret.
  string.contains(shell, "if root.completions-open: Rectangle {")
  |> should.be_true
}

// The context menu opens where the click happened.
pub fn context_menu_opens_at_the_click_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(
    shell,
    "root.context-menu(data.id + \";\" + round((data.x + self.mouse-x) / 1px)",
  )
  |> should.be_true
  string.contains(
    shell,
    "x: max(0px, min(root.context-x, root.surface-w - 158px));",
  )
  |> should.be_true
}

// Tabs keep their place: opening appends, switching never reorders.
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

// Right-clicking a component that is already in the multi-selection keeps
// the whole selection, so the Align submenu stays available.
pub fn context_menu_keeps_multi_selection_test() {
  let model =
    demo_state()
    |> state.select("pet-button")
    |> state.toggle_select("feed-button")
  let opened = state.open_context_menu(model, "pet-button")
  opened.context_open |> should.be_true
  list.length(opened.selection) |> should.equal(2)

  // Right-clicking outside the selection selects that component instead.
  let other = state.open_context_menu(model, "panel-1")
  other.selection |> should.equal(["panel-1"])

  // Opening the menu resets the Align submenu; closing clears both.
  let align_open = state.toggle_context_align(opened)
  align_open.context_align |> should.be_true
  let closed = state.close_context_menu(align_open)
  closed.context_open |> should.be_false
  closed.context_align |> should.be_false
}

// The code editor: a keystroke auto-commits the buffer into the module
// source (F7/F5 always compile what is on screen); completions open only on
// a forced request (Ctrl+Space) or after a dot, merging the Campy context
// with server results filtered by the typed word; accepting splices the
// insert at the caret and auto-commits again.
pub fn code_editor_completion_flow_test() {
  let model = demo_state() |> state.select("pet-button")
  let typed = "pub fn pet_button_clicked() -> Nil {\n  pe\n}\n"

  let edited = state.code_edit(model, "1;4;" <> typed)
  edited.caret |> should.equal(#(1, 4))
  // Auto-committed: the module source is the live buffer.
  let assert Some(module) = state.active_module(edited)
  module.source |> should.equal(typed)

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
  // The segment filter still applies: "pe" keeps only matches.
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
  module.source
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

// The window is a three-pane layout: navigator, centre, inspector must be
// siblings inside main_area's HorizontalLayout. Guards against brace slips
// that silently restructure the generated tree.
pub fn shell_keeps_three_pane_layout_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  string.contains(shell, "main_area()") |> should.be_false
  // The main_area HorizontalLayout opens and the navigator's VerticalLayout
  // is its first child; the centre and right pane follow as siblings.
  string.contains(shell, "project-list := ListView {") |> should.be_true
  string.contains(shell, "module-list := ListView {") |> should.be_true
  string.contains(shell, "if root.code-view: Rectangle {") |> should.be_true
  // The right pane's tab grid comes after the centre's canvases in source
  // order, at the same nesting depth (both are children of the Horizontal).
  let navigator = string.contains(shell, "VerticalLayout { width: 190px;")
  navigator |> should.be_true
  string.contains(shell, "VerticalLayout { width: 320px; spacing: 6px;")
  |> should.be_true
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
  // The inspector grid models must apply too — including a mixed
  // multi-selection whose differing Align choice arrives as index -1.
  let multi =
    model
    |> state.select("pet-button")
    |> state.toggle_select("search-edit")
    |> state.set_align(campy_form.Top)
  let multi_snapshot = ide_ui.snapshot(multi)
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(
        1,
        "prop-items",
        ide_ui.props_wire(multi_snapshot.props),
      ),
    )
  let assert Ok(_) =
    campy_bridge.submit(
      session,
      campy_bridge.SetModel(
        1,
        "event-items",
        ide_ui.props_wire(multi_snapshot.events),
      ),
    )
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

// Ordering actions: overlapping siblings can be brought to front / moved to
// back from the selection, and the step is undoable.
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
// generated run window, the live preview, and the clipboard.
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

  // Generated run window.
  let assert Some(form) = state.active_form(set)
  let assert Ok(source) = preview.to_slint(form)
  string.contains(source, "opacity: 0.4;") |> should.be_true

  // Live preview.
  let snapshot = live_preview.snapshot(form)
  let assert [_, picture, ..] = snapshot.controls
  picture.transparency |> should.equal(60)

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

// F6 swaps in new beams while the running process still holds state built by
// the previous code. A project saved by an older format must be reloaded from
// disk before the new code reads its records; a current one passes through.
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

// The design-surface grid is baked at 24px spacing, so its extent must cover
// the largest surface the model allows (window position ≤ 2000, form size
// ≤ 4096, +28 title bar +80 margin → 6176x6204), and the surface stretches to
// at least the visible pane so an enlarged window keeps its grid.
pub fn canvas_grid_covers_the_whole_surface_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  // Last baked lines: 257*24 = 6168, 258*24 = 6192.
  string.contains(shell, "x: 6168px") |> should.be_true
  string.contains(shell, "y: 6192px") |> should.be_true
  // The surface is at least as large as the pane, whatever the window size.
  string.contains(shell, "width: max(root.surface-w, parent.width)")
  |> should.be_true
  string.contains(shell, "height: max(root.surface-h, parent.height)")
  |> should.be_true
}

// Dragging previews the whole selection: the pressed control follows its own
// drag delta, the other selected controls follow a shared window-level offset
// published while dragging. The offset only applies to the rest of the
// selection when the pressed control was itself selected, so the preview
// matches the commit (which replaces the selection otherwise).
pub fn multi_selection_drag_previews_together_test() {
  let assert Ok(shell) = ide_ui.to_slint(demo_state())
  // Pressed control: local delta; others: shared offset while multi-dragging.
  string.contains(
    shell,
    "x: free-layout ? (root.live-drag-id == data.id ? drag-x : root.live-drag-active && root.live-drag-multi && data.selected ? root.live-drag-offset-x : 0px) : 0px;",
  )
  |> should.be_true
  string.contains(
    shell,
    "y: free-layout ? (root.live-drag-id == data.id ? drag-y : root.live-drag-active && root.live-drag-multi && data.selected ? root.live-drag-offset-y : 0px) : 0px;",
  )
  |> should.be_true
  // Pressing arms the shared offset (multi = the pressed control's selected
  // flag); moving publishes it; releasing resets it.
  string.contains(
    shell,
    "root.live-drag-id = id; root.live-drag-active = true; root.live-drag-multi = control.selected;",
  )
  |> should.be_true
  string.contains(
    shell,
    "drag-shift-x(dx) => { root.live-drag-offset-x = dx; }",
  )
  |> should.be_true
  string.contains(
    shell,
    "root.live-drag-active = false; root.live-drag-id = \"\";",
  )
  |> should.be_true
  // The moved handler publishes the shift alongside the drop-target cursor.
  string.contains(shell, "root.drag-shift-x(drag-x);") |> should.be_true
  // Resize handles hide while a live drag is in progress.
  string.contains(
    shell,
    "if designing && free-layout && data.primary && !live-drag-active:",
  )
  |> should.be_true
}

// Placement and drag-drop share one hit-tester (campy_form.container_at_*),
// which resolves rendered bounds — so a control placed inside an aligned
// container's computed area is adopted by it, matching drag-drop reparenting.
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
