// The IDE shell's data side, protocol v2.
//
// `snapshot` turns IDE state into the shell's `ShellView` (what every section
// displays); `shell.desc` turns that view into the `ControlDesc` document.
// `ops` diffs two views and returns the granular wire ops that move the loaded
// window from one to the other — `SetText`/`SetBool`/`SetInt`/`SetModel`/
// `SetGeometry`/`SetCode`/`AppendConsole`/`SetMarks`, addressed by section wire
// id. When the canvas subtree changes shape (a control is added or removed, or
// another module with a different form is opened) or a LoadUi-level value
// changes (the window title or the light/dark theme), no granular op can
// express it, so `ops` returns a single `Reload` (the same LoadUi path F6
// uses); the caller must reset its diff baseline after reloading, which also
// replays the console and the diagnostic marks on the next sync.
//
// The shell document is loaded once at startup (`load_commands`) and the
// document is never rebuilt for ordinary edits.
//
// Control ids are `campy_form.wire_id(<section name>)`; the names are listed in
// `campy_ide/shell`'s module doc. `Reload` carries the whole view, so `commands`
// can rebuild the document without the IDE state.

import campy_bridge as bridge
import campy_ccl
import campy_form
import campy_form/live_preview
import campy_form/project
import campy_form/syntax
import campy_ide/shell
import campy_ide/state.{
  type Popup, type Scheme, type State, CodeView, Dark, FormView, Light, NoPopup,
  OpenFile, PickPicture, PickProjectIcon, SaveAs, Solarized, active_form,
  active_module, is_events_tab, selection_label,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Snapshot =
  shell.ShellView

pub type ProjectItem =
  shell.ProjectItem

pub type ModuleItem =
  shell.ModuleItem

pub type TabItem =
  shell.TabItem

pub type ControlItem =
  shell.ControlItem

pub type TokenItem =
  shell.TokenItem

pub type LineItem =
  shell.LineItem

pub type CompletionItem =
  shell.CompletionItem

pub type DiagItem =
  shell.DiagItem

pub type BrowserItem =
  shell.BrowserItem

pub type PropItem =
  shell.PropItem

/// One granular change to the loaded shell. Wire ids, no generations.
pub type UiOp {
  SetText(control: Int, value: String)
  SetBool(control: Int, key: String, value: Bool)
  SetInt(control: Int, key: String, value: Int)
  SetModel(control: Int, items: List(bridge.WireValue))
  SetGeometry(control: Int, x: Int, y: Int, w: Int, h: Int)
  SetCode(control: Int, source: String)
  AppendConsole(control: Int, bytes: String)
  SetMarks(control: Int, layer: String, items: List(#(Int, Int, String)))
  /// The document must be rebuilt (structural change); the old shell's F6 path.
  Reload(view: Snapshot)
}

// ---------------------------------------------------------------------------
// State → view
// ---------------------------------------------------------------------------

pub fn snapshot(model: State) -> Snapshot {
  let form = active_form(model)
  let title = case form {
    Some(value) -> value.title
    None -> ""
  }
  let #(window_x, window_y) = state.window_position(model)
  shell.ShellView(
    title: model.project.title,
    theme: case is_dark_scheme(model.scheme) {
      True -> "dark"
      False -> "light"
    },
    status: model.status,
    path: model.project.path,
    running: is_running(model),
    code_view: is_code_view(model),
    raw_tab: model.slint_tab,
    events_tab: is_events_tab(model),
    hints: model.hints,
    has_selection: !list.is_empty(model.selection),
    selection_label: selection_label(model),
    can_delete_project: list.length(model.workspace.projects) > 1,
    has_project_icon: model.project.icon != "",
    project_icon: model.project.icon,
    project_title: model.project.title,
    project_path: model.project.path,
    project_selected: model.selected_project,
    settings_open: model.settings_open,
    agent_open: model.agent_open,
    project_dialog_open: model.project_dialog_open,
    mcp_enabled: model.mcp_enabled,
    mcp_port: int.to_string(model.mcp_port),
    mcp_status: model.mcp_status,
    context_open: model.context_open,
    context_align: model.context_align,
    context_x: model.context_x,
    context_y: model.context_y,
    selection_count: list.length(model.selection),
    nav_context_open: model.nav_context_open,
    nav_context_project: model.nav_kind == "project",
    popup_open: popup_open(model.popup),
    popup_title: popup_title(model.popup),
    popup_action: popup_action(model.popup),
    browser_dir: browser_dir(model),
    browser_name: browser_name(model),
    font: model.font,
    font_size: model.font_size,
    scheme_index: scheme_index(model.scheme),
    form_title: title,
    window_x: window_x,
    window_y: window_y,
    projects: projects(model),
    modules: modules(model),
    tabs: tabs(model),
    controls: controls(model),
    canvas: canvas(model),
    canvas_selection: canvas_selection(model),
    props: prop_items(model),
    events: event_items(model),
    completions: completions(model),
    diagnostics: diagnostics(model),
    browser_items: browser_items(model),
    code: code(model),
    code_source: code_source(model),
    code_handler: code_handler_label(model),
    console_lines: model.console,
  )
}

/// The diff baseline (everything empty).
pub fn empty_snapshot() -> Snapshot {
  shell.empty_view()
}

fn projects(model: State) -> List(ProjectItem) {
  list.map(model.workspace.projects, fn(project) {
    shell.ProjectItem(
      id: project.path,
      title: project.title,
      active: project.path == model.project.path,
      icon: project.icon,
    )
  })
}

fn modules(model: State) -> List(ModuleItem) {
  list.map(model.project.modules, fn(module) {
    shell.ModuleItem(module.id, module.name, module.id == model.active)
  })
}

fn tabs(model: State) -> List(TabItem) {
  list.filter_map(model.opened, fn(id) {
    case project.find_module(model.project, id) {
      Some(module) ->
        Ok(shell.TabItem(module.id, module.name, module.id == model.active))
      None -> Error(Nil)
    }
  })
}

// The designer canvas document: the active form's `ControlDesc` tree (window
// root included; `shell.desc` re-keys the root and keeps the designed wire ids).
fn canvas(model: State) -> List(bridge.ControlDesc) {
  case active_form(model) {
    Some(form) -> live_preview.to_controls(form)
    None -> []
  }
}

fn controls(model: State) -> List(ControlItem) {
  case active_form(model) {
    None -> []
    Some(form) ->
      list.map(campy_form.render_controls(form), fn(control) {
        let #(x, y, w, h) = campy_form.bounds(form, control)
        shell.ControlItem(
          id: control.id,
          kind: campy_form.kind_key(control.kind),
          text: control.text,
          x: x,
          y: y,
          w: w,
          h: h,
          enabled: control.enabled,
          visible: control.visible,
          selected: list.contains(model.selection, control.id),
          primary: model.selected == Some(control.id),
          picture: case control.kind {
            campy_form.Picture -> control.text
            _ -> ""
          },
          value: control_value(control),
          transparency: campy_form.transparency_of(form, control.id),
          arranged: campy_form.layout_of(
            form,
            campy_form.parent_of(form, control.id),
          )
            != campy_form.Free,
          checked: prop_bool(control, "checked"),
          placeholder: prop(control, "placeholder"),
          read_only: prop_bool(control, "read-only"),
          minimum: prop_int(control, "minimum", 0),
          maximum: prop_int(control, "maximum", 100),
          current_index: prop_int(control, "current-index", 0),
          items: item_list(control),
        )
      })
  }
}

fn item_list(control: campy_form.Control) -> List(String) {
  control.text
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
}

// The selection outline in canvas coordinates (form window offset + borders).
fn canvas_selection(model: State) -> #(Int, Int, Int, Int) {
  case active_form(model) {
    None -> #(0, 0, 0, 0)
    Some(form) -> {
      let #(window_x, window_y) = state.window_position(model)
      let boxes =
        model.selection
        |> list.filter_map(fn(id) {
          case campy_form.find_control(form, id) {
            Some(control) -> {
              let #(x, y, w, h) = campy_form.bounds(form, control)
              Ok(#(window_x + x, window_y + 28 + y, w, h))
            }
            None -> Error(Nil)
          }
        })
      union_boxes(boxes)
    }
  }
}

fn union_boxes(boxes: List(#(Int, Int, Int, Int))) -> #(Int, Int, Int, Int) {
  case boxes {
    [] -> #(0, 0, 0, 0)
    [first, ..rest] -> list.fold(rest, first, union_box)
  }
}

fn union_box(
  outer: #(Int, Int, Int, Int),
  inner: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int) {
  let #(x1, y1, w1, h1) = outer
  let #(x2, y2, w2, h2) = inner
  let left = int.min(x1, x2)
  let top = int.min(y1, y2)
  let right = int.max(x1 + w1, x2 + w2)
  let bottom = int.max(y1 + h1, y2 + h2)
  #(left, top, right - left, bottom - top)
}

// ---------------------------------------------------------------------------
// Inspector grid rows
// ---------------------------------------------------------------------------

// Properties tab: one row per property of the selection (common keys only
// when several components are selected), or the module window's properties
// when nothing is selected. Row kinds/labels come from `shell`, so the row
// pool and the visible rows can never disagree.
pub fn prop_items(model: State) -> List(PropItem) {
  case model.selected_project, model.selection, active_form(model) {
    True, _, _ -> []
    False, [_, ..], Some(form) ->
      merge_rows(list.map(model.selection, fn(id) { control_rows(form, id) }))
    False, _, _ -> window_rows(model)
  }
}

// Events tab: the events the selected components have in common. The value is
// the derived handler name (blank when the selection is mixed, since handler
// names embed the component name).
pub fn event_items(model: State) -> List(PropItem) {
  case model.selected_project, model.selection, active_form(model) {
    True, _, _ -> []
    False, [_, ..], Some(form) ->
      merge_rows(
        list.map(model.selection, fn(id) { control_event_rows(form, id) }),
      )
    False, _, _ -> []
  }
}

// Keep only the row keys present in every list, preserving the first list's
// order. Where values disagree the value becomes blank (and mixed choices
// become index -1).
fn merge_rows(row_lists: List(List(PropItem))) -> List(PropItem) {
  case row_lists {
    [] -> []
    [first, ..rest] ->
      list.filter_map(first, fn(row) {
        let matches =
          list.filter_map(rest, fn(rows) {
            case list.find(rows, fn(candidate) { candidate.key == row.key }) {
              Ok(found) -> Ok(found)
              Error(_) -> Error(Nil)
            }
          })
        case list.length(matches) == list.length(rest) {
          False -> Error(Nil)
          True -> Ok(uniform_row(row, matches))
        }
      })
  }
}

fn uniform_row(row: PropItem, others: List(PropItem)) -> PropItem {
  let same =
    list.all(others, fn(other) {
      other.value == row.value
      && other.checked == row.checked
      && other.index == row.index
    })
  case same {
    True -> row
    False -> shell.PropItem(..row, value: "", checked: False, index: -1)
  }
}

fn control_rows(form: campy_form.Form, id: String) -> List(PropItem) {
  case campy_form.find_control(form, id) {
    None -> []
    Some(control) -> {
      let geometry = [
        number_row("x", int.to_string(control.x)),
        number_row("y", int.to_string(control.y)),
        number_row("w", int.to_string(control.width)),
        number_row("h", int.to_string(control.height)),
      ]
      let picture = case control.kind {
        campy_form.Picture -> [
          open_row("picture", control.text),
          number_row(
            "transparency",
            int.to_string(campy_form.transparency_of(form, id)),
          ),
        ]
        _ -> []
      }
      let align = case form.layout {
        campy_form.Free -> [
          choice_row(
            "align",
            shell.align_options,
            index_of(
              ["none", "top", "bottom", "left", "right", "client", "fill"],
              campy_form.align_key(campy_form.align_of(form, id)),
            ),
          ),
        ]
        _ -> []
      }
      let container = case campy_form.accepts_children(control.kind) {
        True -> [
          choice_row(
            "layout",
            shell.layout_options,
            layout_index_of(campy_form.layout_of(form, id)),
          ),
          number_row("border", int.to_string(campy_form.border_of(form, id))),
        ]
        False -> []
      }
      let color = [
        color_row("color", campy_form.color_of(form, id)),
      ]
      // Component properties from the CCL schema: one row per declared
      // property, edited per its declared type. The universal `text` row and
      // the container layout/border rows are already covered above (Z1.1 note:
      // `text` must route to the same editor as the control's text field).
      let skip = case campy_form.accepts_children(control.kind) {
        True -> ["text", "layout", "border"]
        False -> ["text"]
      }
      let schema =
        campy_ccl.properties(campy_form.kind_key(control.kind))
        |> list.filter(fn(property: campy_ccl.Property) {
          !list.contains(skip, property.key)
        })
        |> list.map(fn(property: campy_ccl.Property) {
          let value =
            campy_form.control_prop(control, property.key, property.default)
          case property.kind {
            campy_ccl.Text -> text_row(property.key, value)
            campy_ccl.Number -> number_row(property.key, value)
            campy_ccl.Bool -> bool_row(property.key, value == "true")
          }
        })
      dedupe_rows(
        list.flatten([
          [text_row("name", control.name), text_row("text", control.text)],
          schema,
          picture,
          geometry,
          color,
          align,
          container,
          [
            bool_row("enabled", control.enabled),
            bool_row("visible", control.visible),
          ],
        ]),
      )
    }
  }
}

// One row per key (the schema and the IDE's own rows can overlap).
fn dedupe_rows(rows: List(PropItem)) -> List(PropItem) {
  case rows {
    [] -> []
    [first, ..rest] ->
      case list.any(rest, fn(row) { row.key == first.key }) {
        True -> dedupe_rows(rest)
        False -> [first, ..dedupe_rows(rest)]
      }
  }
}

fn control_event_rows(form: campy_form.Form, id: String) -> List(PropItem) {
  case campy_form.find_control(form, id) {
    None -> []
    Some(control) ->
      campy_ccl.events(campy_form.kind_key(control.kind))
      |> list.map(fn(event: campy_ccl.Event) {
        shell.PropItem(
          event.key,
          shell.row_label(event.key),
          "event",
          campy_form.handler_name(control, event.key),
          False,
          0,
          [],
          "Opens handler code",
        )
      })
  }
}

fn window_rows(model: State) -> List(PropItem) {
  case active_form(model) {
    None -> []
    Some(form) -> [
      text_row("title", form.title),
      number_row("width", int.to_string(form.width)),
      number_row("height", int.to_string(form.height)),
      choice_row("layout", shell.layout_options, layout_index_of(form.layout)),
      number_row("border", int.to_string(campy_form.border_of(form, ""))),
    ]
  }
}

fn layout_index_of(layout: campy_form.Layout) -> Int {
  case layout {
    campy_form.Free -> 0
    campy_form.Column -> 1
    campy_form.Row -> 2
  }
}

fn text_row(key: String, value: String) -> PropItem {
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    value,
    False,
    0,
    [],
    hint_of(key),
  )
}

fn number_row(key: String, value: String) -> PropItem {
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    value,
    False,
    0,
    [],
    hint_of(key),
  )
}

fn bool_row(key: String, checked: Bool) -> PropItem {
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    "",
    checked,
    0,
    [],
    hint_of(key),
  )
}

fn choice_row(key: String, options: List(String), index: Int) -> PropItem {
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    "",
    False,
    index,
    options,
    hint_of(key),
  )
}

fn open_row(key: String, value: String) -> PropItem {
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    value,
    False,
    0,
    [],
    hint_of(key),
  )
}

fn color_row(key: String, value: String) -> PropItem {
  let name = case value {
    "" -> "Default"
    hex -> hex
  }
  shell.PropItem(
    key,
    shell.row_label(key),
    shell.row_kind_key(key),
    "",
    False,
    index_of(shell.color_options, name),
    shell.color_options,
    hint_of(key),
  )
}

// Terse per-property hints shown as tooltips in the inspector.
fn hint_of(key: String) -> String {
  case key {
    "name" -> "Unique component name"
    "text" -> "Caption or content"
    "x" -> "Left edge, px"
    "y" -> "Top edge, px"
    "w" -> "Width, px"
    "h" -> "Height, px"
    "color" -> "Component color"
    "align" -> "Alignment in parent"
    "layout" -> "Child layout"
    "border" -> "Inner padding, px"
    "enabled" -> "Accepts input"
    "visible" -> "Shown when running"
    "transparency" -> "Image opacity, %"
    "picture" -> "Image file path"
    "title" -> "Window title"
    "width" -> "Window width, px"
    "height" -> "Window height, px"
    "placeholder" -> "Text when empty"
    "read-only" -> "Blocks editing"
    "checked" -> "Selected state"
    "minimum" -> "Slider low end"
    "maximum" -> "Slider high end"
    "current-index" -> "Selected item, 0-based"
    _ -> ""
  }
}

// Both inspector models share the same wire shape.
pub fn props_wire(items: List(PropItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("key", bridge.WireText(item.key)),
      #("label", bridge.WireText(item.label)),
      #("kind", bridge.WireText(item.kind)),
      #("value", bridge.WireText(item.value)),
      #("checked", bridge.WireBool(item.checked)),
      #("index", bridge.WireInt(item.index)),
      #("options", bridge.WireList(list.map(item.options, bridge.WireText))),
      #("hint", bridge.WireText(item.hint)),
    ])
  })
}

// The completion popup rows (Campy model items merged with LSP results).
pub fn completions(model: State) -> List(CompletionItem) {
  list.map(model.completions, fn(item) {
    shell.CompletionItem(item.label, item.detail, item.insert)
  })
}

pub fn console_lines(model: State) -> List(String) {
  model.console
}

pub fn diagnostics(model: State) -> List(DiagItem) {
  list.map(model.diagnostics, fn(diagnostic) {
    let #(line, severity, message) = diagnostic
    shell.DiagItem(line, severity, message)
  })
}

pub fn completions_wire(items: List(CompletionItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("label", bridge.WireText(item.label)),
      #("detail", bridge.WireText(item.detail)),
      #("insert", bridge.WireText(item.insert)),
    ])
  })
}

pub fn diagnostics_wire(items: List(DiagItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("line", bridge.WireInt(item.line)),
      #("severity", bridge.WireInt(item.severity)),
      #("message", bridge.WireText(item.message)),
    ])
  })
}

fn code_source(model: State) -> String {
  case active_module(model) {
    Some(module) -> module_text(module)
    None -> ""
  }
}

// An `External` module's text lives on disk; the IDE loop reads it (Z2.3's
// seam). Pure `ide_ui` can only see embedded sources.
fn module_text(module: project.Module) -> String {
  case module.source_origin {
    project.Embedded(text) -> text
    project.External(_) -> ""
  }
}

fn code(model: State) -> List(LineItem) {
  case active_module(model) {
    None -> []
    Some(module) ->
      module_text(module)
      |> string.split("\n")
      |> list.map(fn(line) {
        shell.LineItem(
          list.map(syntax.tokenize(line), fn(token) {
            case token {
              syntax.Token(kind, text) ->
                shell.TokenItem(text, token_kind(kind))
            }
          }),
        )
      })
  }
}

fn token_kind(kind: syntax.Kind) -> String {
  case kind {
    syntax.Space -> "space"
    syntax.Comment -> "comment"
    syntax.Keyword -> "keyword"
    syntax.Str -> "string"
    syntax.Number -> "number"
    syntax.TypeName -> "type"
    syntax.Name -> "name"
    syntax.Punct -> "punct"
  }
}

// ---------------------------------------------------------------------------
// Wire format (legacy model encoders kept for the smoke/probe helpers)
// ---------------------------------------------------------------------------

pub fn projects_wire(items: List(ProjectItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("id", bridge.WireText(item.id)),
      #("title", bridge.WireText(item.title)),
      #("active", bridge.WireBool(item.active)),
      #("icon", bridge.WireImage(item.icon)),
      #("has-icon", bridge.WireBool(item.icon != "")),
    ])
  })
}

pub fn modules_wire(items: List(ModuleItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("id", bridge.WireText(item.id)),
      #("name", bridge.WireText(item.name)),
      #("active", bridge.WireBool(item.active)),
    ])
  })
}

pub fn tabs_wire(items: List(TabItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("id", bridge.WireText(item.id)),
      #("name", bridge.WireText(item.name)),
      #("active", bridge.WireBool(item.active)),
    ])
  })
}

pub fn controls_wire(items: List(ControlItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("id", bridge.WireText(item.id)),
      #("kind", bridge.WireText(item.kind)),
      #("text", bridge.WireText(item.text)),
      #("x", bridge.WireInt(item.x)),
      #("y", bridge.WireInt(item.y)),
      #("w", bridge.WireInt(item.w)),
      #("h", bridge.WireInt(item.h)),
      #("enabled", bridge.WireBool(item.enabled)),
      #("visible", bridge.WireBool(item.visible)),
      #("selected", bridge.WireBool(item.selected)),
      #("primary", bridge.WireBool(item.primary)),
      #("picture", bridge.WireImage(item.picture)),
      #("value", bridge.WireInt(item.value)),
      #("transparency", bridge.WireInt(item.transparency)),
      #("arranged", bridge.WireBool(item.arranged)),
    ])
  })
}

pub fn code_wire(items: List(LineItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #(
        "tokens",
        bridge.WireList(
          list.map(item.tokens, fn(token) {
            bridge.WireStruct([
              #("text", bridge.WireText(token.text)),
              #("kind", bridge.WireText(token.kind)),
            ])
          }),
        ),
      ),
    ])
  })
}

pub fn browser_wire(items: List(BrowserItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("name", bridge.WireText(item.name)),
      #("is-dir", bridge.WireBool(item.is_dir)),
    ])
  })
}

pub fn console_wire(items: List(String)) -> List(bridge.WireValue) {
  list.map(items, bridge.WireText)
}

// ---------------------------------------------------------------------------
// Document and ops
// ---------------------------------------------------------------------------

/// The startup/F6 command list: one `LoadUi` of the whole shell.
pub fn load_commands(generation: Int, model: State) -> List(bridge.Command) {
  let view = snapshot(model)
  [
    bridge.LoadUi(
      generation,
      shell.window_title(view.title),
      shell.window_width,
      shell.window_height,
      view.theme,
      shell.desc(view),
    ),
  ]
}

/// Translate view-level ops into generation-tagged bridge commands.
pub fn commands(generation: Int, ops: List(UiOp)) -> List(bridge.Command) {
  list.map(ops, fn(op) {
    case op {
      SetText(control, value) -> bridge.SetText(generation, control, value)
      SetBool(control, key, value) ->
        bridge.SetBool(generation, control, key, value)
      SetInt(control, key, value) ->
        bridge.SetInt(generation, control, key, value)
      SetModel(control, items) -> bridge.SetModel(generation, control, items)
      SetGeometry(control, x, y, w, h) ->
        bridge.SetGeometry(generation, control, x, y, w, h)
      SetCode(control, source) -> bridge.SetCode(generation, control, source)
      AppendConsole(control, bytes) ->
        bridge.AppendConsole(generation, control, bytes)
      SetMarks(control, layer, items) ->
        bridge.SetMarks(generation, control, layer, items)
      Reload(view) ->
        bridge.LoadUi(
          generation,
          shell.window_title(view.title),
          shell.window_width,
          shell.window_height,
          view.theme,
          shell.desc(view),
        )
    }
  })
}

/// The granular ops that move the loaded window from `previous` to `next`.
pub fn ops(previous: Snapshot, next: Snapshot) -> List(UiOp) {
  case window_changed(previous, next) {
    True -> [Reload(next)]
    False ->
      case diff_controls(shell.desc(previous), shell.desc(next)) {
        Error(_) -> [Reload(next)]
        Ok(changes) ->
          list.append(
            list.map(changes, change_op),
            list.append(
              code_ops(previous, next),
              list.append(
                console_ops(previous, next),
                marks_ops(previous, next),
              ),
            ),
          )
      }
  }
}

// The window itself (title, theme) is LoadUi-level: no granular op carries it.
fn window_changed(previous: Snapshot, next: Snapshot) -> Bool {
  previous.title != next.title || previous.theme != next.theme
}

// --- description tree diff -------------------------------------------------

type Change {
  TextChange(control: Int, value: String)
  BoolChange(control: Int, key: String, value: Bool)
  IntChange(control: Int, key: String, value: Int)
  GeoChange(control: Int, x: Int, y: Int, w: Int, h: Int)
  ModelChange(control: Int, items: List(bridge.WireValue))
}

fn change_op(change: Change) -> UiOp {
  case change {
    TextChange(control, value) -> SetText(control, value)
    BoolChange(control, key, value) -> SetBool(control, key, value)
    IntChange(control, key, value) -> SetInt(control, key, value)
    GeoChange(control, x, y, w, h) -> SetGeometry(control, x, y, w, h)
    ModelChange(control, items) -> SetModel(control, items)
  }
}

fn diff_controls(
  previous: List(bridge.ControlDesc),
  next: List(bridge.ControlDesc),
) -> Result(List(Change), Nil) {
  case list.length(previous) == list.length(next) {
    False -> Error(Nil)
    True -> diff_pairs(previous, next)
  }
}

fn diff_pairs(
  previous: List(bridge.ControlDesc),
  next: List(bridge.ControlDesc),
) -> Result(List(Change), Nil) {
  case previous, next {
    [], [] -> Ok([])
    [old, ..old_rest], [new, ..new_rest] ->
      case diff_control(old, new) {
        Error(error) -> Error(error)
        Ok(changes) ->
          case diff_pairs(old_rest, new_rest) {
            Error(error) -> Error(error)
            Ok(rest) -> Ok(list.append(changes, rest))
          }
      }
    _, _ -> Error(Nil)
  }
}

fn diff_control(
  previous: bridge.ControlDesc,
  next: bridge.ControlDesc,
) -> Result(List(Change), Nil) {
  case previous.id == next.id && previous.kind == next.kind {
    False -> Error(Nil)
    True ->
      case own_changes(previous, next) {
        Error(error) -> Error(error)
        Ok(changes) ->
          case diff_controls(previous.children, next.children) {
            Error(error) -> Error(error)
            Ok(child_changes) -> Ok(list.append(changes, child_changes))
          }
      }
  }
}

fn own_changes(
  previous: bridge.ControlDesc,
  next: bridge.ControlDesc,
) -> Result(List(Change), Nil) {
  let id = next.id
  let text_changes = case text_drives_itself(next.kind) {
    True -> []
    False ->
      case previous.text == next.text {
        True -> []
        False -> [TextChange(id, next.text)]
      }
  }
  let enabled_changes = case previous.enabled == next.enabled {
    True -> []
    False -> [BoolChange(id, "enabled", next.enabled)]
  }
  let geometry = case
    #(previous.x, previous.y, previous.w, previous.h)
    == #(next.x, next.y, next.w, next.h)
  {
    True -> []
    False -> [GeoChange(id, next.x, next.y, next.w, next.h)]
  }
  // Visibility goes last, so a row that appears is already positioned.
  let visibility = case previous.visible == next.visible {
    True -> []
    False -> [BoolChange(id, "visible", next.visible)]
  }
  case diff_props(id, previous.props, next.props) {
    Error(error) -> Error(error)
    Ok(prop_changes) ->
      Ok(list.append(
        text_changes,
        list.append(
          enabled_changes,
          list.append(geometry, list.append(prop_changes, visibility)),
        ),
      ))
  }
}

// Editor/memo/console content is driven by SetCode/AppendConsole, never by
// SetText (the renderer's text signal does not feed an editor buffer).
fn text_drives_itself(kind: String) -> Bool {
  case kind {
    "code_editor" | "memo" | "console" -> True
    _ -> False
  }
}

fn diff_props(
  id: Int,
  previous: List(#(String, bridge.WireValue)),
  next: List(#(String, bridge.WireValue)),
) -> Result(List(Change), Nil) {
  case list.length(previous) == list.length(next) {
    False -> Error(Nil)
    True -> diff_prop_entries(id, previous, next, [])
  }
}

fn diff_prop_entries(
  id: Int,
  previous: List(#(String, bridge.WireValue)),
  next: List(#(String, bridge.WireValue)),
  acc: List(Change),
) -> Result(List(Change), Nil) {
  case next {
    [] -> Ok(list.reverse(acc))
    [entry, ..rest] -> {
      let #(key, value) = entry
      case find_prop(previous, key) {
        None -> Error(Nil)
        Some(old) ->
          case old == value {
            True -> diff_prop_entries(id, previous, rest, acc)
            False ->
              case prop_change(id, key, value) {
                Ok(change) ->
                  diff_prop_entries(id, previous, rest, [change, ..acc])
                Error(_) -> Error(Nil)
              }
          }
      }
    }
  }
}

fn find_prop(
  props: List(#(String, bridge.WireValue)),
  key: String,
) -> Option(bridge.WireValue) {
  case props {
    [] -> None
    [#(name, value), ..rest] ->
      case name == key {
        True -> Some(value)
        False -> find_prop(rest, key)
      }
  }
}

// Props a granular op can move. Anything else changing (placeholder, layout,
// minimum, …) is structural: the shell only varies these values at runtime.
fn prop_change(
  id: Int,
  key: String,
  value: bridge.WireValue,
) -> Result(Change, Nil) {
  case key, value {
    "model", bridge.WireList(items) -> Ok(ModelChange(id, items))
    "checked", bridge.WireBool(checked) -> Ok(BoolChange(id, key, checked))
    "value", bridge.WireInt(number) -> Ok(IntChange(id, key, number))
    "current-index", bridge.WireInt(number) -> Ok(IntChange(id, key, number))
    _, _ -> Error(Nil)
  }
}

// --- content ops ------------------------------------------------------------

fn code_ops(previous: Snapshot, next: Snapshot) -> List(UiOp) {
  case previous.code_source == next.code_source {
    True -> []
    False -> [
      SetCode(shell.section_id("code-view"), next.code_source),
      SetCode(shell.section_id("raw-view"), next.code_source),
    ]
  }
}

fn console_ops(previous: Snapshot, next: Snapshot) -> List(UiOp) {
  let id = shell.section_id("console")
  case next.console_lines {
    [] ->
      case previous.console_lines {
        [] -> []
        _ -> [AppendConsole(id, clear_console())]
      }
    lines ->
      case is_prefix(previous.console_lines, lines) {
        True -> {
          let fresh = list.drop(lines, list.length(previous.console_lines))
          case fresh {
            [] -> []
            _ -> [AppendConsole(id, string.join(fresh, "\n") <> "\n")]
          }
        }
        False -> [
          AppendConsole(id, clear_console() <> string.join(lines, "\n") <> "\n"),
        ]
      }
  }
}

fn clear_console() -> String {
  "\u{1b}[2J\u{1b}[H"
}

fn is_prefix(prefix: List(String), list_: List(String)) -> Bool {
  case prefix, list_ {
    [], _ -> True
    [_, ..], [] -> False
    [head, ..tail], [other, ..rest] ->
      case head == other {
        True -> is_prefix(tail, rest)
        False -> False
      }
  }
}

fn marks_ops(previous: Snapshot, next: Snapshot) -> List(UiOp) {
  case
    previous.diagnostics == next.diagnostics
    && previous.code_source == next.code_source
  {
    True -> []
    False -> [
      SetMarks(
        shell.section_id("code-view"),
        "diagnostics",
        diagnostic_spans(next.code_source, next.diagnostics),
      ),
    ]
  }
}

fn diagnostic_spans(
  source: String,
  diagnostics: List(DiagItem),
) -> List(#(Int, Int, String)) {
  let lines = string.split(source, "\n")
  diagnostics
  |> list.filter_map(fn(diagnostic: DiagItem) {
    case line_span(lines, diagnostic.line) {
      Some(#(start, length)) -> {
        let class = case diagnostic.severity {
          1 -> "error"
          _ -> "warning"
        }
        Ok(#(start, start + length, class))
      }
      None -> Error(Nil)
    }
  })
}

// Char offset/length of one source line.
fn line_span(lines: List(String), line: Int) -> Option(#(Int, Int)) {
  line_span_loop(lines, line, 0)
}

fn line_span_loop(
  lines: List(String),
  target: Int,
  offset: Int,
) -> Option(#(Int, Int)) {
  case lines {
    [] -> None
    [text, ..rest] ->
      case target <= 0 {
        True -> Some(#(offset, string.length(text)))
        False -> {
          let next_offset = offset + string.length(text) + 1
          line_span_loop(rest, target - 1, next_offset)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// State accessors
// ---------------------------------------------------------------------------

fn is_running(model: State) -> Bool {
  case model.preview {
    Some(_) -> True
    None -> False
  }
}

fn is_code_view(model: State) -> Bool {
  case model.view {
    CodeView -> True
    FormView -> False
  }
}

fn code_handler_label(model: State) -> String {
  case model.active_handler {
    Some(handler) -> handler
    None -> state.active_name(model)
  }
}

fn browser_dir(model: State) -> String {
  case model.browser {
    Some(browser) -> browser.dir
    None -> ""
  }
}

fn browser_name(model: State) -> String {
  case model.browser {
    Some(browser) -> browser.name
    None -> ""
  }
}

fn browser_items(model: State) -> List(BrowserItem) {
  case model.browser {
    Some(browser) ->
      list.map(browser.entries, fn(entry) {
        shell.BrowserItem(entry.name, entry.is_dir)
      })
    None -> []
  }
}

fn popup_open(popup: Popup) -> Bool {
  case popup {
    NoPopup -> False
    _ -> True
  }
}

fn popup_title(popup: Popup) -> String {
  case popup {
    NoPopup -> ""
    OpenFile -> "Open project"
    SaveAs -> "Save project as"
    PickPicture -> "Choose picture"
    PickProjectIcon -> "Choose project icon"
  }
}

fn popup_action(popup: Popup) -> String {
  case popup {
    NoPopup -> ""
    OpenFile -> "Open"
    SaveAs -> "Save"
    PickPicture -> "Use picture"
    PickProjectIcon -> "Use icon"
  }
}

fn control_value(control: campy_form.Control) -> Int {
  case int.parse(control.text) {
    Ok(value) -> int.max(0, int.min(100, value))
    Error(_) -> 50
  }
}

// Schema property values with CCL defaults for the designer preview wire.
fn prop(control: campy_form.Control, key: String) -> String {
  campy_form.control_prop(
    control,
    key,
    campy_ccl.prop_default(campy_form.kind_key(control.kind), key),
  )
}

fn prop_bool(control: campy_form.Control, key: String) -> Bool {
  prop(control, key) == "true"
}

fn prop_int(control: campy_form.Control, key: String, default: Int) -> Int {
  case int.parse(prop(control, key)) {
    Ok(value) -> value
    Error(_) -> default
  }
}

fn index_of(items: List(String), value: String) -> Int {
  index_of_loop(items, value, 0)
}

fn index_of_loop(items: List(String), value: String, index: Int) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case first == value {
        True -> index
        False -> index_of_loop(rest, value, index + 1)
      }
  }
}

fn is_dark_scheme(scheme: Scheme) -> Bool {
  case scheme {
    Light -> False
    Dark -> True
    Solarized -> True
  }
}

fn scheme_index(scheme: Scheme) -> Int {
  case scheme {
    Dark -> 0
    Light -> 1
    Solarized -> 2
  }
}
