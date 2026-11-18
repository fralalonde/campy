import campy_ide_model as model
import campy_ide_wx
import campy_project
import campy_view.{VInt, VText}
import campy_wx
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn module(slug: String) -> campy_project.Module {
  campy_project.Module(
    slug: slug,
    form: campy_view.Document(
      schema: 1,
      view: campy_view.node("form", "root"),
      extra: [],
    ),
    handlers: "",
  )
}

fn project() -> campy_project.Project {
  campy_project.Project(
    title: "Demo",
    modules: [module("greeter"), module("notes")],
    extra: [],
  )
}

pub fn navigator_lists_the_project_and_modules_test() {
  let state = model.new(project())
  campy_ide_wx.project_items(state) |> should.equal(["Demo"])
  campy_ide_wx.module_items(state) |> should.equal(["greeter", "notes"])
  campy_ide_wx.module_index(state) |> should.equal(0)

  let notes = model.update(state, model.OpenModule("notes"))
  campy_ide_wx.module_index(notes) |> should.equal(1)
}

pub fn inspector_reports_the_active_module_test() {
  let rows = campy_ide_wx.inspector_rows(model.new(project()))

  rows
  |> should.equal([
    ["title", "greeter"],
    ["w", "640"],
    ["h", "480"],
    ["layout", "free"],
    ["module", "greeter"],
    ["undo", "0"],
    ["redo", "0"],
  ])
}

pub fn status_and_console_start_empty_test() {
  let state = model.new(project())
  state.console |> should.equal([])
  state.status |> should.equal("")
}

pub fn handlers_are_text_test() {
  let state = model.new(project())
  let assert Ok(active) = model.active_module(state)
  active.handlers |> should.equal("")
  active.slug |> should.equal("greeter")
}

pub fn document_title_is_available_test() {
  let assert Ok(active) = model.active_module(model.new(project()))
  campy_view.prop(active.form.view, "title") |> should.equal(Error(Nil))

  let labelled =
    campy_project.Module(
      slug: "x",
      form: campy_view.Document(
        schema: 1,
        view: campy_view.node("form", "root")
          |> campy_view.with_props([#("title", VText("X"))]),
        extra: [],
      ),
      handlers: "",
    )

  campy_view.prop(labelled.form.view, "title")
  |> should.equal(Ok(VText("X")))
}

pub fn palette_lists_every_catalog_widget_test() {
  let labels = campy_ide_wx.palette_labels()
  labels |> list.length |> should.equal(16)
  labels |> list.first |> should.equal(Ok("Panel"))
  labels |> list.contains("Panel") |> should.equal(True)
}

pub fn inspector_shows_the_parent_of_a_control_test() {
  let view =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", campy_view.VInt(400)),
      #("h", campy_view.VInt(300)),
    ])
    |> campy_view.with_child(
      campy_view.node("button", "ok")
      |> campy_view.with_props([
        #("x", campy_view.VInt(10)),
        #("y", campy_view.VInt(12)),
        #("w", campy_view.VInt(80)),
        #("h", campy_view.VInt(30)),
      ]),
    )

  let state =
    model.new(
      campy_project.Project(
        title: "Demo",
        modules: [
          campy_project.Module(
            slug: "main",
            form: campy_view.Document(schema: 1, view: view, extra: []),
            handlers: "",
          ),
        ],
        extra: [],
      ),
    )
    |> model.select_controls(["ok"])

  campy_ide_wx.inspector_rows(state)
  |> should.equal([
    ["id", "ok"],
    ["kind", "button"],
    ["parent", "root"],
    ["x", "10"],
    ["y", "12"],
    ["w", "80"],
    ["h", "30"],
    ["text", ""],
  ])
}

pub fn inspector_reports_resolved_geometry_for_column_children_test() {
  let view =
    campy_view.node("form", "root")
    |> campy_view.with_props([
      #("w", campy_view.VInt(600)),
      #("h", campy_view.VInt(400)),
      #("layout", VText("column")),
    ])
    |> campy_view.with_children([
      campy_view.node("label", "a")
        |> campy_view.with_props([
          #("h", campy_view.VInt(20)),
          #("text", VText("A")),
        ]),
      campy_view.node("label", "b")
        |> campy_view.with_props([
          #("h", campy_view.VInt(20)),
          #("text", VText("B")),
        ]),
    ])

  let state =
    model.new(
      campy_project.Project(
        title: "Demo",
        modules: [
          campy_project.Module(
            slug: "main",
            form: campy_view.Document(schema: 1, view: view, extra: []),
            handlers: "",
          ),
        ],
        extra: [],
      ),
    )
    |> model.select_controls(["b"])

  campy_ide_wx.inspector_rows(state)
  |> should.equal([
    ["id", "b"],
    ["kind", "label"],
    ["parent", "root"],
    ["x", "0"],
    ["y", "24"],
    ["w", "600"],
    ["h", "20"],
    ["text", "B"],
  ])
}

// --- T2.3: inspector and events -------------------------------------------

fn state_from(view: campy_view.Node, selection: List(String)) -> model.State {
  model.new(
    campy_project.Project(
      title: "Demo",
      modules: [
        campy_project.Module(
          slug: "main",
          form: campy_view.Document(schema: 1, view: view, extra: []),
          handlers: "",
        ),
      ],
      extra: [],
    ),
  )
  |> model.select_controls(selection)
}

fn design_form(children: List(campy_view.Node)) -> campy_view.Node {
  campy_view.node("form", "root")
  |> campy_view.with_props([
    #("w", VInt(600)),
    #("h", VInt(400)),
  ])
  |> campy_view.with_children(children)
}

fn sized_button(id: String, text: String, x: Int, y: Int) -> campy_view.Node {
  campy_view.node("button", id)
  |> campy_view.with_props([
    #("x", VInt(x)),
    #("y", VInt(y)),
    #("w", VInt(80)),
    #("h", VInt(30)),
    #("text", VText(text)),
  ])
  |> campy_view.with_events(["click"])
}

pub fn inspector_reports_absolute_geometry_for_nested_controls_test() {
  let view =
    design_form([
      campy_view.node("panel", "panel")
      |> campy_view.with_props([
        #("x", VInt(100)),
        #("y", VInt(80)),
        #("w", VInt(300)),
        #("h", VInt(200)),
      ])
      |> campy_view.with_child(sized_button("ok", "Go", 20, 20)),
    ])

  campy_ide_wx.inspector_rows(state_from(view, ["ok"]))
  |> should.equal([
    ["id", "ok"],
    ["kind", "button"],
    ["parent", "panel"],
    ["x", "120"],
    ["y", "100"],
    ["w", "80"],
    ["h", "30"],
    ["text", "Go"],
  ])
}

pub fn multi_selection_shows_common_values_and_blanks_the_rest_test() {
  let view =
    design_form([
      sized_button("first", "Go", 10, 20),
      sized_button("second", "Stop", 120, 20),
    ])

  campy_ide_wx.inspector_rows(state_from(view, ["first", "second"]))
  |> should.equal([
    ["selected", "2"],
    ["kind", "button"],
    ["parent", "root"],
    ["x", ""],
    ["y", "20"],
    ["w", "80"],
    ["h", "30"],
    ["text", ""],
  ])
}

pub fn events_list_follows_the_selected_control_test() {
  let view =
    design_form([
      sized_button("ok", "Go", 10, 10),
      campy_view.node("text", "name")
        |> campy_view.with_props([#("text", VText(""))])
        |> campy_view.with_events(["change"]),
    ])

  campy_ide_wx.event_items(state_from(view, [])) |> should.equal([])
  campy_ide_wx.event_items(state_from(view, ["ok"]))
  |> should.equal(["click"])
  campy_ide_wx.event_items(state_from(view, ["ok", "name"]))
  |> should.equal([])
}

pub fn page_index_tracks_form_code_and_source_test() {
  let state = model.new(project())
  campy_ide_wx.page_index(state) |> should.equal(0)

  let code = model.update(state, model.ToggleCodeView)
  campy_ide_wx.page_index(code) |> should.equal(1)

  let source = model.update(code, model.ToggleSourceView)
  campy_ide_wx.page_index(source) |> should.equal(2)
  source.source_view |> should.be_true()
  source.code_view |> should.be_false()

  let form = model.update(source, model.ToggleSourceView)
  campy_ide_wx.page_index(form) |> should.equal(0)
}

pub fn source_text_is_generated_for_the_active_module_test() {
  let state = model.new(project())
  let source = campy_ide_wx.source_text(state)

  string.contains(source, "modules/greeter/form.json") |> should.be_true()
  string.contains(source, "pub fn view() -> Node") |> should.be_true()
  string.contains(source, "campy_view.node(\"form\", \"root\")")
  |> should.be_true()
}

pub fn source_text_changes_when_the_form_changes_test() {
  let state = model.new(project())
  let before = campy_ide_wx.source_text(state)
  let assert Ok(module) = model.active_module(state)

  let edited =
    campy_view.node("form", "root")
    |> campy_view.with_props([#("title", VText("Edited in T2.4"))])
    |> campy_view.with_children([
      campy_view.node("label", "hello")
      |> campy_view.with_props([#("text", VText("Changed"))]),
    ])

  let state = model.commit_view(state, module, edited)
  let after = campy_ide_wx.source_text(state)
  let unchanged = after == before
  unchanged |> should.be_false()
  string.contains(after, "Edited in T2.4") |> should.be_true()
  string.contains(after, "Changed") |> should.be_true()
}

// --- T2.5: shell layout, inspector dock, shortcuts -------------------------

pub fn palette_uses_short_labels_test() {
  let labels = campy_ide_wx.palette_labels()
  labels |> list.length |> should.equal(16)
  labels
  |> should.equal([
    "Panel", "Group", "Label", "Button", "Text", "Memo", "Check", "Radio",
    "Choice", "List", "Slider", "Progress", "Picture", "Tree", "Grid", "Editor",
  ])
}

pub fn selection_title_names_the_control_test() {
  let view = design_form([sized_button("button_1", "Go", 10, 20)])
  let state = state_from(view, [])

  campy_ide_wx.selection_title(state) |> should.equal("Window — main")
  campy_ide_wx.selection_title(model.select_controls(state, ["root"]))
  |> should.equal("Window — root")
  campy_ide_wx.selection_title(model.select_controls(state, ["button_1"]))
  |> should.equal("button_1 — button")
  campy_ide_wx.selection_title(
    model.select_controls(state, ["button_1", "root"]),
  )
  |> should.equal("2 selected")
}

pub fn centre_header_reports_module_and_canvas_test() {
  let state = state_from(design_form([]), [])
  campy_ide_wx.centre_header(state)
  |> should.equal("main    Canvas 600 × 400")
}

fn key(code: String, control: Bool, shift: Bool) -> campy_wx.Key {
  campy_wx.Key(code: code, control: control, shift: shift, alt: False)
}

pub fn shortcuts_map_editing_keys_test() {
  let state = model.new(project())

  campy_ide_wx.shortcut(state, key("s", True, False))
  |> should.equal(campy_ide_wx.Save)
  campy_ide_wx.shortcut(state, key("q", True, False))
  |> should.equal(campy_ide_wx.Quit)
  campy_ide_wx.shortcut(state, key("z", True, False))
  |> should.equal(campy_ide_wx.Undo)
  campy_ide_wx.shortcut(state, key("z", True, True))
  |> should.equal(campy_ide_wx.Redo)
  campy_ide_wx.shortcut(state, key("y", True, False))
  |> should.equal(campy_ide_wx.Redo)
  campy_ide_wx.shortcut(state, key("d", True, False))
  |> should.equal(campy_ide_wx.Duplicate)
  campy_ide_wx.shortcut(state, key("escape", False, False))
  |> should.equal(campy_ide_wx.Cancel)
  campy_ide_wx.shortcut(state, key("2", True, False))
  |> should.equal(campy_ide_wx.ShowCodePage)
}

pub fn shortcuts_leave_editor_text_keys_alone_test() {
  let state = model.new(project()) |> model.update(model.ShowCode)

  campy_ide_wx.shortcut(state, key("z", True, False))
  |> should.equal(campy_ide_wx.NoShortcut)
  campy_ide_wx.shortcut(state, key("c", True, False))
  |> should.equal(campy_ide_wx.NoShortcut)
  campy_ide_wx.shortcut(state, key("v", True, False))
  |> should.equal(campy_ide_wx.NoShortcut)
  campy_ide_wx.shortcut(state, key("s", True, False))
  |> should.equal(campy_ide_wx.Save)
  campy_ide_wx.shortcut(state, key("3", True, False))
  |> should.equal(campy_ide_wx.ShowSourcePage)
}

pub fn delete_shortcut_requires_a_selection_test() {
  let state = model.new(project())
  campy_ide_wx.shortcut(state, key("delete", False, False))
  |> should.equal(campy_ide_wx.NoShortcut)

  let selected = model.select_controls(state, ["hello"])
  campy_ide_wx.shortcut(selected, key("delete", False, False))
  |> should.equal(campy_ide_wx.DeleteControl)
}

pub fn accelerator_actions_map_to_shortcuts_test() {
  campy_ide_wx.accelerator_shortcut("save") |> should.equal(campy_ide_wx.Save)
  campy_ide_wx.accelerator_shortcut("undo") |> should.equal(campy_ide_wx.Undo)
  campy_ide_wx.accelerator_shortcut("redo") |> should.equal(campy_ide_wx.Redo)
  campy_ide_wx.accelerator_shortcut("delete")
  |> should.equal(campy_ide_wx.DeleteControl)
  campy_ide_wx.accelerator_shortcut("code")
  |> should.equal(campy_ide_wx.ShowCodePage)
  campy_ide_wx.accelerator_shortcut("nope")
  |> should.equal(campy_ide_wx.NoShortcut)
}

pub fn events_display_lists_only_declared_events_test() {
  let view = design_form([sized_button("ok", "Go", 10, 10)])
  campy_ide_wx.events_display(state_from(view, ["ok"]))
  |> should.equal(["click"])
  campy_ide_wx.events_display(state_from(view, []))
  |> should.equal([])
}

// --- T2.5: hit-tested handle zones ----------------------------------------

pub fn handle_roles_come_from_corners_first_test() {
  let rect = #(100, 80, 200, 100)

  campy_ide_wx.handle_role_at(rect, 100, 80) |> should.equal(Some(0))
  campy_ide_wx.handle_role_at(rect, 300, 80) |> should.equal(Some(2))
  campy_ide_wx.handle_role_at(rect, 300, 180) |> should.equal(Some(4))
  campy_ide_wx.handle_role_at(rect, 100, 180) |> should.equal(Some(6))
}

pub fn handle_roles_on_edges_test() {
  let rect = #(100, 80, 200, 100)

  campy_ide_wx.handle_role_at(rect, 200, 78) |> should.equal(Some(1))
  campy_ide_wx.handle_role_at(rect, 302, 130) |> should.equal(Some(3))
  campy_ide_wx.handle_role_at(rect, 250, 182) |> should.equal(Some(5))
  campy_ide_wx.handle_role_at(rect, 98, 130) |> should.equal(Some(7))
}

pub fn handle_role_tolerates_the_9px_handle_size_test() {
  let rect = #(100, 80, 200, 100)

  campy_ide_wx.handle_role_at(rect, 94, 74) |> should.equal(Some(0))
  campy_ide_wx.handle_role_at(rect, 306, 186) |> should.equal(Some(4))
  campy_ide_wx.handle_role_at(rect, 93, 74) |> should.equal(None)
  campy_ide_wx.handle_role_at(rect, 200, 130) |> should.equal(None)
}

/// The language server analysis copy rewrites the handlers dialect's dotted
/// member imports into braced ones, one-for-one, so line numbers still map.
pub fn analysis_text_rewrites_dotted_imports_test() {
  let handlers =
    "//// Greeter handlers.\n"
    <> "\n"
    <> "import campy_app.{type Effect, type Event, Log}\n"
    <> "import campy_view.VText\n"
    <> "import gleam/int\n"
    <> "\n"
    <> "pub fn main() {\n"
    <> "  Nil\n"
    <> "}\n"

  campy_ide_wx.analysis_text(handlers)
  |> should.equal(
    "//// Greeter handlers.\n"
    <> "\n"
    <> "import campy_app.{type Effect, type Event, Log}\n"
    <> "import campy_view.{VText}\n"
    <> "import gleam/int\n"
    <> "\n"
    <> "pub fn main() {\n"
    <> "  Nil\n"
    <> "}\n",
  )
}

/// Module-path imports (gleam/int) and braced imports pass through; the line
/// count never changes, keeping diagnostics and the editor aligned.
pub fn analysis_text_preserves_lines_and_module_paths_test() {
  let handlers =
    "import campy_view.VText\nimport gleam/int\nimport campy_app.{Log}\n"

  let analysed = campy_ide_wx.analysis_text(handlers)

  string.split(analysed, "\n") |> list.length |> should.equal(4)
  should.equal(
    analysed,
    "import campy_view.{VText}\nimport gleam/int\nimport campy_app.{Log}\n",
  )
}

/// The Code editor's handlers document lives in the generated analysis
/// workspace as one file per module.
pub fn handlers_path_points_at_the_analysis_workspace_test() {
  let path = campy_ide_wx.handlers_path("../../examples/demo", "greeter")

  should.be_true(string.ends_with(path, "/src/greeter_handlers.gleam"))
  should.be_true(string.contains(path, "generated/lsp/demo"))
  // The server echoes canonical, dot-free URIs; our paths must match.
  should.be_false(string.contains(path, ".."))
}

/// Dot segments collapse: the IDE's cwd-relative root becomes a plain
/// absolute path, so the paths the language server echoes match.
pub fn canonical_path_collapses_dot_segments_test() {
  campy_ide_wx.canonical_path("/a/b/../c") |> should.equal("/a/c")
  campy_ide_wx.canonical_path("/a/./b/") |> should.equal("/a/b")
  campy_ide_wx.canonical_path("/a/b/c/../../../d") |> should.equal("/d")
}
