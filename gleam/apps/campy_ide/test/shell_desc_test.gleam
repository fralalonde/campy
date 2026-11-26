// Pure tests for the protocol-v2 IDE shell: the `ControlDesc` tree the emitter
// builds, the stable wire ids of its sections, and the granular op sequences
// the view diff produces. No session, no display: every case runs offline.

import campy_bridge as bridge
import campy_ccl
import campy_form
import campy_form/live_preview
import campy_form/project
import campy_ide/ide_ui
import campy_ide/shell
import campy_ide/state
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

fn demo_state() -> state.State {
  state.initial(project.campy())
}

fn demo_view() -> ide_ui.Snapshot {
  ide_ui.snapshot(demo_state())
}

fn flatten(controls: List(bridge.ControlDesc)) -> List(bridge.ControlDesc) {
  list.flat_map(controls, fn(control) { [control, ..flatten(control.children)] })
}

fn by_name(
  controls: List(bridge.ControlDesc),
  name: String,
) -> bridge.ControlDesc {
  let id = shell.section_id(name)
  case list.find(flatten(controls), fn(control) { control.id == id }) {
    Ok(control) -> control
    Error(_) -> panic as { "missing shell section " <> name }
  }
}

fn has(controls: List(bridge.ControlDesc), name: String) -> Bool {
  let id = shell.section_id(name)
  list.any(flatten(controls), fn(control) { control.id == id })
}

fn prop(control: bridge.ControlDesc, key: String) -> bridge.WireValue {
  case list.find(control.props, fn(entry) { entry.0 == key }) {
    Ok(entry) -> entry.1
    Error(_) -> bridge.WireBool(False)
  }
}

fn model_texts(control: bridge.ControlDesc) -> List(String) {
  case prop(control, "model") {
    bridge.WireList(items) ->
      list.map(items, fn(item) {
        case item {
          bridge.WireText(text) -> text
          _ -> ""
        }
      })
    _ -> []
  }
}

fn view_with(
  update: fn(shell.ShellView) -> shell.ShellView,
) -> ide_ui.Snapshot {
  update(shell.empty_view())
}

fn prop_row(key: String, value: String) -> shell.PropItem {
  shell.PropItem(
    key: key,
    label: shell.row_label(key),
    kind: shell.row_kind_key(key),
    value: value,
    checked: False,
    index: 0,
    options: [],
    hint: "",
  )
}

// ---------------------------------------------------------------------------
// Structure
// ---------------------------------------------------------------------------

pub fn every_wire_contract_section_is_present_test() {
  let document = shell.desc(demo_view())
  let expected = [
    #("menu-bar", "panel"),
    #("menu-file", "menu"),
    #("menu-edit", "menu"),
    #("menu-settings", "menu"),
    #("palette", "panel"),
    #("view-toggle", "button"),
    #("status", "label"),
    #("projects-nav", "list"),
    #("modules-nav", "list"),
    #("tab-strip", "panel"),
    #("canvas", "surface"),
    #("inspector", "panel"),
    #("inspector-events", "panel"),
    #("code-view", "code_editor"),
    #("console", "console"),
    #("settings-panel", "panel"),
    #("agent-panel", "panel"),
    #("project-dialog", "panel"),
    #("browser-panel", "panel"),
  ]
  list.each(expected, fn(entry) {
    let #(name, kind) = entry
    by_name(document, name).kind |> should.equal(kind)
  })
}

pub fn root_is_the_window_root_and_ids_are_unique_test() {
  let document = shell.desc(demo_view())
  let assert [root, ..] = document
  root.id |> should.equal(campy_form.window_id)
  let ids =
    flatten(document)
    |> list.map(fn(control) { control.id })
    |> list.sort(int.compare)
  list.unique(ids) |> should.equal(ids)
}

pub fn section_ids_are_stable_wire_ids_test() {
  let document = shell.desc(demo_view())
  let names = [
    "menu-bar", "palette", "status", "projects-nav", "tab-strip", "canvas",
    "inspector", "code-view", "console", "settings-panel", "context-menu",
    "nav-context",
  ]
  list.each(names, fn(name) {
    by_name(document, name).id |> should.equal(campy_form.wire_id(name))
    has(document, name) |> should.be_true
  })
  // Every inspector row is `insp:<key>`.
  list.each(shell.prop_keys(), fn(key) {
    by_name(document, "insp:" <> key).id
    |> should.equal(campy_form.wire_id("insp:" <> key))
  })
}

pub fn canvas_carries_the_designed_controls_test() {
  let view = demo_view()
  let document = shell.desc(view)
  by_name(document, "canvas").kind |> should.equal("surface")
  // The form root is re-keyed so it can never collide with the window root.
  let form = by_name(document, "canvas-form")
  form.id |> should.equal(campy_form.wire_id("canvas-form"))
  list.length(flatten(form.children))
  |> should.equal(list.length(view.controls))
  // The module's own controls keep their form wire ids.
  let designed = flatten(form.children) |> list.map(fn(control) { control.id })
  list.each(view.controls, fn(item) {
    list.contains(designed, campy_form.wire_id(item.id)) |> should.be_true
  })
}

pub fn menus_keep_every_old_item_test() {
  let document = shell.desc(demo_view())
  model_texts(by_name(document, "menu-file"))
  |> should.equal([
    "New project    Ctrl+N",
    "New module    Ctrl+Shift+N",
    "—",
    "Open…    Ctrl+O",
    "Save    Ctrl+S",
    "Save As…    Ctrl+Shift+S",
    "—",
    "Quit    Ctrl+Q",
  ])
  model_texts(by_name(document, "menu-edit"))
  |> should.equal([
    "Undo    Ctrl+Z",
    "Redo    Ctrl+Shift+Z",
    "—",
    "Copy component    Ctrl+C",
    "Cut component    Ctrl+X",
    "Paste component    Ctrl+V",
    "—",
    "Delete component    Del",
    "—",
    "Bring to front",
    "Move to back",
    "—",
    "Update running app    F7",
    "Reload Campy code    F6",
  ])
  model_texts(by_name(document, "menu-settings"))
  |> should.equal(["Editor…", "Agent…"])
}

pub fn palette_has_one_tile_per_ccl_entry_test() {
  let document = shell.desc(demo_view())
  let palette = by_name(document, "palette")
  list.length(palette.children)
  |> should.equal(list.length(campy_ccl.all()))
  list.each(campy_ccl.all(), fn(component) {
    let tile = by_name(document, "tile:" <> component.key)
    tile.kind |> should.equal("button")
    tile.text |> should.equal(component.icon)
  })
}

pub fn dialogs_are_hidden_panels_test() {
  let document = shell.desc(demo_view())
  list.each(
    [
      "settings-panel", "agent-panel", "project-dialog", "browser-panel",
      "context-menu", "align-menu", "nav-context",
    ],
    fn(name) { by_name(document, name).visible |> should.be_false },
  )
  // The old dialogs keep their fields.
  by_name(document, "settings-font").kind |> should.equal("combo")
  by_name(document, "settings-size").kind |> should.equal("combo")
  by_name(document, "settings-scheme").kind |> should.equal("combo")
  by_name(document, "settings-hints").kind |> should.equal("checkbox")
  by_name(document, "settings-close").kind |> should.equal("button")
  by_name(document, "agent-mcp").kind |> should.equal("checkbox")
  by_name(document, "agent-port").kind |> should.equal("edit")
  by_name(document, "agent-close").kind |> should.equal("button")
  by_name(document, "project-new").kind |> should.equal("button")
  by_name(document, "project-dialog-cancel").kind |> should.equal("button")
  by_name(document, "browser-name").kind |> should.equal("edit")
  by_name(document, "browser-entries").kind |> should.equal("list")
  model_texts(by_name(document, "settings-scheme"))
  |> should.equal(shell.schemes)
}

pub fn inspector_rows_follow_the_row_vocabulary_test() {
  let document = shell.desc(demo_view())
  by_name(document, "insp:text").kind |> should.equal("edit")
  by_name(document, "insp:x").kind |> should.equal("edit")
  by_name(document, "insp:enabled").kind |> should.equal("checkbox")
  by_name(document, "insp:picture").kind |> should.equal("button")
  by_name(document, "insp:layout").kind |> should.equal("combo")
  model_texts(by_name(document, "insp:layout"))
  |> should.equal(shell.layout_options)
  by_name(document, "insp:color").kind |> should.equal("combo")
  model_texts(by_name(document, "insp:color"))
  |> should.equal(shell.color_options)
  // Event rows are click-to-open buttons.
  by_name(document, "insp:clicked").kind |> should.equal("button")
  by_name(document, "inspector-events").visible |> should.be_false
}

// ---------------------------------------------------------------------------
// Ops
// ---------------------------------------------------------------------------

pub fn status_text_change_is_one_set_text_op_test() {
  let previous = view_with(fn(view) { view })
  let next = view_with(fn(view) { shell.ShellView(..view, status: "Busy") })
  ide_ui.ops(previous, next)
  |> should.equal([ide_ui.SetText(campy_form.wire_id("status"), "Busy")])
}

pub fn list_model_change_is_one_set_model_op_test() {
  let previous = view_with(fn(view) { view })
  let next =
    view_with(fn(view) {
      shell.ShellView(..view, projects: [
        shell.ProjectItem("p1", "Demo", True, ""),
      ])
    })
  let rows = [
    bridge.WireStruct([
      #("text", bridge.WireText("Demo")),
      #("id", bridge.WireText("p1")),
      #("active", bridge.WireBool(True)),
      #("icon", bridge.WireText("")),
    ]),
  ]
  ide_ui.ops(previous, next)
  |> should.equal([ide_ui.SetModel(campy_form.wire_id("projects-nav"), rows)])
}

pub fn visibility_and_geometry_are_granular_ops_test() {
  let previous =
    view_with(fn(view) { shell.ShellView(..view, props: [prop_row("x", "10")]) })
  let next =
    view_with(fn(view) {
      shell.ShellView(..view, props: [prop_row("x", "10"), prop_row("y", "20")])
    })
  let label = campy_form.wire_id("insp:y:label")
  let row = campy_form.wire_id("insp:y")
  ide_ui.ops(previous, next)
  |> should.equal([
    ide_ui.SetGeometry(label, 8, 38, 96, 28),
    ide_ui.SetBool(label, "visible", True),
    ide_ui.SetText(row, "20"),
    ide_ui.SetGeometry(row, 108, 38, 204, 28),
    ide_ui.SetBool(row, "visible", True),
  ])
}

pub fn context_menu_follows_its_pointer_op_test() {
  let menu = campy_form.wire_id("context-menu")
  let align = campy_form.wire_id("align-menu")
  let previous =
    view_with(fn(view) {
      shell.ShellView(
        ..view,
        context_open: True,
        context_x: 100,
        context_y: 200,
      )
    })
  let next =
    view_with(fn(view) {
      shell.ShellView(
        ..view,
        context_open: True,
        context_x: 140,
        context_y: 200,
      )
    })
  ide_ui.ops(previous, next)
  |> should.equal([
    ide_ui.SetGeometry(menu, 140, 200, 150, 142),
    ide_ui.SetGeometry(align, 290, 200, 110, 166),
  ])
}

pub fn code_change_is_set_code_ops_test() {
  let source = "pub fn main() { Nil }"
  let previous = view_with(fn(view) { view })
  let next =
    view_with(fn(view) { shell.ShellView(..view, code_source: source) })
  ide_ui.ops(previous, next)
  |> should.equal([
    ide_ui.SetCode(campy_form.wire_id("code-view"), source),
    ide_ui.SetMarks(campy_form.wire_id("code-view"), "diagnostics", []),
  ])
}

pub fn console_delta_appends_only_new_lines_test() {
  let previous =
    view_with(fn(view) { shell.ShellView(..view, console_lines: ["a"]) })
  let next =
    view_with(fn(view) { shell.ShellView(..view, console_lines: ["a", "b"]) })
  ide_ui.ops(previous, next)
  |> should.equal([ide_ui.AppendConsole(campy_form.wire_id("console"), "b\r\n")])
  // A reset clears the terminal first (ANSI clear, then the full log).
  ide_ui.ops(
    view_with(fn(view) { shell.ShellView(..view, console_lines: ["a"]) }),
    view_with(fn(view) { shell.ShellView(..view, console_lines: ["z"]) }),
  )
  |> should.equal([
    ide_ui.AppendConsole(
      campy_form.wire_id("console"),
      "\u{1b}[2J\u{1b}[H" <> "z\r\n",
    ),
  ])
}

pub fn diagnostics_become_marks_test() {
  let source = "a\nbc\n"
  let previous =
    view_with(fn(view) { shell.ShellView(..view, code_source: source) })
  let next =
    view_with(fn(view) {
      shell.ShellView(..view, code_source: source, diagnostics: [
        shell.DiagItem(1, 1, "boom"),
      ])
    })
  ide_ui.ops(previous, next)
  |> should.equal([
    ide_ui.SetMarks(campy_form.wire_id("code-view"), "diagnostics", [
      #(2, 4, "error"),
    ]),
  ])
}

pub fn theme_change_reloads_the_document_test() {
  let previous = view_with(fn(view) { view })
  let next = view_with(fn(view) { shell.ShellView(..view, theme: "light") })
  ide_ui.ops(previous, next) |> should.equal([ide_ui.Reload(next)])
}

pub fn canvas_shape_change_reloads_the_document_test() {
  let form = campy_form.demo_form()
  let previous = view_with(fn(view) { view })
  let next =
    view_with(fn(view) {
      shell.ShellView(..view, canvas: live_preview.to_controls(form))
    })
  ide_ui.ops(previous, next) |> should.equal([ide_ui.Reload(next)])
}

pub fn canvas_geometry_change_is_granular_test() {
  let assert Some(form) = state.active_form(demo_state())
  let moved =
    campy_form.update_selected(form, "pet-button", fn(control) {
      campy_form.Control(..control, x: control.x + 40)
    })
  let previous =
    view_with(fn(view) {
      shell.ShellView(..view, canvas: live_preview.to_controls(form))
    })
  let next =
    view_with(fn(view) {
      shell.ShellView(..view, canvas: live_preview.to_controls(moved))
    })
  let ops = ide_ui.ops(previous, next)
  list.any(ops, fn(op) {
    case op {
      ide_ui.SetGeometry(control, _, _, _, _) ->
        control == campy_form.wire_id("pet-button")
      _ -> False
    }
  })
  |> should.be_true
}

pub fn navigator_rows_carry_run_buttons_test() {
  let document = shell.desc(demo_view())
  let find = fn(name) {
    let id = shell.section_id(name)
    case list.find(flatten(document), fn(control) { control.id == id }) {
      Ok(control) -> control
      Error(_) -> panic as { "missing navigator control " <> name }
    }
  }
  // One run button per module row, at the row's right end.
  list.each([0, 1, 2], fn(index) {
    let button = find("run-m:" <> int.to_string(index))
    button.kind |> should.equal("button")
    button.x |> should.equal(158)
    button.y |> should.equal(197 + index * 24)
    button.visible |> should.be_true
  })
  // A slot past the last row stays in the document, hidden, so the shape of
  // the shell does not change with the number of modules.
  find("run-m:5").visible |> should.be_false
  // The project row runs the project's app (the demo names `cat-cafe`).
  find("run-p:0").visible |> should.be_true
  // Without an app there is no button on the row.
  shell.desc(shell.empty_view())
  |> flatten
  |> list.find(fn(control) { control.id == shell.section_id("run-p:0") })
  |> should.be_ok
  |> fn(found) { found.visible }
  |> should.be_false
  // The ids resolve back through the shell's pools.
  shell.nav_run_name(shell.section_id("run-m:2"))
  |> should.equal(Some("run-m:2"))
}

pub fn every_clickable_control_explains_itself_test() {
  // A hint is the status-line sentence for whatever the pointer is over, so
  // every control that answers a click must carry one.
  let document = shell.desc(demo_view())
  // The canvas holds the designed form: its controls are the user's, not the
  // IDE's chrome.
  let canvas = case
    list.find(flatten(document), fn(control) {
      control.id == shell.section_id("canvas")
    })
  {
    Ok(canvas) ->
      flatten(canvas.children) |> list.map(fn(control) { control.id })
    Error(_) -> []
  }
  let missing =
    flatten(document)
    |> list.filter(fn(control) {
      list.contains(["button", "menu", "combo"], control.kind)
      && !list.contains(canvas, control.id)
    })
    |> list.filter_map(fn(control) {
      let hint =
        control.props
        |> list.find_map(fn(prop) {
          case prop {
            #("hint", bridge.WireText(text)) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> fn(found) {
          case found {
            Ok(text) -> text
            Error(_) -> ""
          }
        }
      case hint {
        "" -> Ok(#(control.kind, control.text))
        _ -> Error(Nil)
      }
    })
  missing |> should.equal([])
}

pub fn each_tab_has_a_close_button_test() {
  let document = shell.desc(demo_view())
  // One × per open tab, at the tab's right end.
  let view = demo_view()
  view.tabs
  |> list.each(fn(item) {
    let module_id = item.id
    let name = "tab-close:" <> module_id
    let close = case
      list.find(flatten(document), fn(control) {
        control.id == shell.section_id(name)
      })
    {
      Ok(control) -> control
      Error(_) -> panic as { "missing tab close " <> name }
    }
    close.kind |> should.equal("button")
    close.text |> should.equal("×")
    let tab = case
      list.find(flatten(document), fn(control) {
        control.id == shell.section_id("tab:" <> module_id)
      })
    {
      Ok(control) -> control
      Error(_) -> panic as { "missing tab " <> module_id }
    }
    close.x |> should.equal(tab.x + tab.w - 24)
    close.props
    |> list.any(fn(prop) {
      case prop {
        #("hint", bridge.WireText(text)) -> string.contains(text, "Close")
        _ -> False
      }
    })
    |> should.be_true
  })
}

pub fn commands_tag_ops_with_the_generation_test() {
  // One op is one command.
  ide_ui.commands(4, [ide_ui.SetText(7, "hi")])
  |> should.equal([bridge.SetText(4, 7, "hi")])

  // Several are one batch: the ops of a diff belong to one moment, and a
  // submit per op used to wake the window (and draw a frame) per op.
  ide_ui.commands(4, [
    ide_ui.SetText(7, "hi"),
    ide_ui.SetBool(8, "visible", True),
  ])
  |> should.equal([
    bridge.Batch(4, [
      bridge.SetText(4, 7, "hi"),
      bridge.SetBool(4, 8, "visible", True),
    ]),
  ])

  ide_ui.commands(4, []) |> should.equal([])
}

pub fn load_commands_start_with_the_whole_shell_test() {
  let model = demo_state()
  let assert [bridge.LoadUi(generation, title, width, height, theme, controls)] =
    ide_ui.load_commands(1, model)
  generation |> should.equal(1)
  width |> should.equal(shell.window_width)
  height |> should.equal(shell.window_height)
  title |> should.equal(shell.window_title(model.project.title))
  theme |> should.equal("dark")
  has(controls, "menu-bar") |> should.be_true
  has(controls, "console") |> should.be_true
  has(controls, "canvas") |> should.be_true
}

pub fn empty_snapshot_produces_no_ops_test() {
  ide_ui.ops(ide_ui.empty_snapshot(), ide_ui.empty_snapshot())
  |> should.equal([])
}

// ---------------------------------------------------------------------------
// Layout: the shell stretches to the window
// ---------------------------------------------------------------------------

pub fn layout_matches_the_designed_frame_test() {
  let l = shell.layout(shell.window_width, shell.window_height)
  l.canvas_x |> should.equal(191)
  l.canvas_y |> should.equal(79)
  l.canvas_w |> should.equal(768)
  l.canvas_h |> should.equal(550)
  l.right_x |> should.equal(960)
  l.console_y |> should.equal(663)
  l.status_y |> should.equal(834)
}

pub fn layout_stretches_the_centre_column_test() {
  let small = shell.layout(1280, 860)
  let large = shell.layout(1700, 1050)
  // The side panes keep their widths; the centre column takes the difference.
  large.nav_w |> should.equal(small.nav_w)
  large.right_w |> should.equal(small.right_w)
  large.centre_w |> should.equal(small.centre_w + 420)
  large.right_x |> should.equal(small.right_x + 420)
  large.canvas_h |> should.equal(small.canvas_h + 190)
  large.status_y |> should.equal(1024)
}

/// A resize is geometry, not a reload: every pane moves with `SetGeometry` and
/// the document keeps its shape, so the console and editor survive it.
pub fn window_resize_moves_the_panes_without_reloading_test() {
  let before = demo_view()
  let resized = state.set_window_size(demo_state(), 1700, 1050)
  let after = ide_ui.snapshot(resized)
  let ops = ide_ui.ops(before, after)
  let reloaded =
    list.any(ops, fn(op) {
      case op {
        ide_ui.Reload(_) -> True
        _ -> False
      }
    })
  reloaded |> should.be_false
  let moved =
    list.any(ops, fn(op) {
      case op {
        ide_ui.SetGeometry(id, _, _, _, _) ->
          id == shell.section_id("status-bar")
          || id == shell.section_id("right-pane")
          || id == shell.section_id("canvas")
        _ -> False
      }
    })
  moved |> should.be_true
}
