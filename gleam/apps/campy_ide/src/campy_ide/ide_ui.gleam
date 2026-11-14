import campy_bridge as bridge
import campy_ccl
import campy_form.{type Form}
import campy_form/preview.{quote}
import campy_form/project
import campy_form/syntax
import campy_ide/shell
import campy_ide/state.{
  type Popup, type Scheme, type State, CodeView, Dark, FormView, Light, NoPopup,
  OpenFile, PickPicture, PickProjectIcon, SaveAs, Solarized, active_form,
  active_module, active_name, can_redo, can_undo, is_events_tab, selection_label,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// The IDE shell is emitted once. Scalar state and theme colors are root
// properties; modules, tabs, canvas controls, palette rows, and code lines are
// Slint models. Nothing reloads the window after startup.
pub type Update {
  TextUpdate(name: String, value: String)
  BoolUpdate(name: String, value: Bool)
  IntUpdate(name: String, value: Int)
  ScalarIntUpdate(name: String, value: Int)
  ColorUpdate(name: String, value: String)
}

pub type ProjectItem {
  ProjectItem(
    id: String,
    title: String,
    active: Bool,
    icon: String,
    has_icon: Bool,
  )
}

pub type ModuleItem {
  ModuleItem(id: String, name: String, active: Bool)
}

pub type TabItem {
  TabItem(id: String, name: String, active: Bool)
}

pub type ControlItem {
  ControlItem(
    id: String,
    kind: String,
    text: String,
    x: Int,
    y: Int,
    w: Int,
    h: Int,
    enabled: Bool,
    visible: Bool,
    selected: Bool,
    primary: Bool,
    picture: String,
    value: Int,
    transparency: Int,
    arranged: Bool,
    checked: Bool,
    placeholder: String,
    read_only: Bool,
    minimum: Int,
    maximum: Int,
    current_index: Int,
    items: List(String),
  )
}

pub type TokenItem {
  TokenItem(text: String, kind: String)
}

pub type CompletionItem {
  CompletionItem(label: String, detail: String, insert: String)
}

pub type DiagItem {
  DiagItem(line: Int, severity: Int, message: String)
}

pub type BrowserItem {
  BrowserItem(name: String, is_dir: Bool)
}

pub type LineItem {
  LineItem(tokens: List(TokenItem))
}

// One row of the inspector grid: a property (or event) name on the left and a
// value display/editor on the right. `kind` selects the editor: "text" and
// "number" are line edits, "bool" a checkbox, "choice" a combo box, and
// "picture"/"event" are click-to-open cells. Blank values mean "differs across
// the selection"; a negative `index` is a mixed choice.
pub type PropItem {
  PropItem(
    key: String,
    label: String,
    kind: String,
    value: String,
    checked: Bool,
    index: Int,
    options: List(String),
    hint: String,
  )
}

pub type Snapshot {
  Snapshot(
    scalars: List(Update),
    projects: List(ProjectItem),
    modules: List(ModuleItem),
    tabs: List(TabItem),
    controls: List(ControlItem),
    code: List(LineItem),
    props: List(PropItem),
    events: List(PropItem),
    completions: List(CompletionItem),
    diagnostics: List(DiagItem),
    code_module: String,
    code_view: Bool,
    browser_items: List(BrowserItem),
    console_lines: List(String),
  )
}

pub fn snapshot(model: State) -> Snapshot {
  Snapshot(
    scalars: scalars(model),
    projects: list.map(model.workspace.projects, fn(project) {
      ProjectItem(
        project.path,
        project.title,
        project.path == model.project.path,
        project.icon,
        project.icon != "",
      )
    }),
    modules: list.map(model.project.modules, fn(module) {
      ModuleItem(module.id, module.name, module.id == model.active)
    }),
    tabs: tabs(model),
    controls: controls(model),
    code: code(model),
    props: prop_items(model),
    events: event_items(model),
    completions: completions(model),
    diagnostics: diagnostics(model),
    code_module: model.active,
    code_view: is_code_view(model),
    browser_items: browser_items(model),
    console_lines: console_lines(model),
  )
}

// After the initial LoadUi the shell already has the scalar defaults; only the
// models need to be pushed.
pub fn without_models(snapshot: Snapshot) -> Snapshot {
  Snapshot(
    ..snapshot,
    projects: [],
    modules: [],
    tabs: [],
    controls: [],
    code: [],
    props: [],
    events: [],
    completions: [],
    diagnostics: [],
    code_module: "",
    code_view: False,
    browser_items: [],
    console_lines: [],
  )
}

// Force the next sync to send every scalar and model (used after a UI reload).
pub fn empty_snapshot() -> Snapshot {
  Snapshot(
    scalars: [],
    projects: [],
    modules: [],
    tabs: [],
    controls: [],
    code: [],
    props: [],
    events: [],
    completions: [],
    diagnostics: [],
    code_module: "",
    code_view: False,
    browser_items: [],
    console_lines: [],
  )
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

fn scalars(model: State) -> List(Update) {
  let form = active_form(model)
  let title = case form {
    Some(value) -> value.title
    None -> ""
  }
  let slint_source = case form {
    Some(value) ->
      case preview.to_slint(value) {
        Ok(source) -> source
        Error(error) -> "// Generated Slint unavailable: " <> error
      }
    None -> "// No module"
  }
  list.append(
    [
      TextUpdate("status", model.status),
      TextUpdate("path-text", model.project.path),
      BoolUpdate("running", is_running(model)),
      BoolUpdate("code-view", is_code_view(model)),
      BoolUpdate("events-tab", is_events_tab(model)),
      BoolUpdate("slint-tab", is_slint_tab(model)),
      BoolUpdate("layout-free", layout_is(form, campy_form.Free)),
      BoolUpdate("layout-column", layout_is(form, campy_form.Column)),
      BoolUpdate("layout-row", layout_is(form, campy_form.Row)),
      BoolUpdate("has-selection", !list.is_empty(model.selection)),
      TextUpdate("insp-selection", selection_label(model)),
      IntUpdate("canvas-w", form_width(form)),
      IntUpdate("canvas-h", form_height(form)),
      IntUpdate("form-border-size", form_border_size(model)),
      IntUpdate("window-x", window_x(model)),
      IntUpdate("window-y", window_y(model)),
      IntUpdate(
        "surface-w",
        int.max(window_x(model) + form_width(form) + 80, 900),
      ),
      IntUpdate(
        "surface-h",
        int.max(window_y(model) + form_height(form) + 28 + 80, 700),
      ),
      TextUpdate("code-handler", code_handler_label(model)),
      TextUpdate("browser-dir", browser_dir(model)),
      TextUpdate("browser-name", browser_name(model)),
      TextUpdate("slint-source", slint_source),
      TextUpdate("console-text", state.console_text(model)),
      TextUpdate("popup-title", popup_title(model.popup)),
      TextUpdate("popup-action", popup_action(model.popup)),
      BoolUpdate("popup-open", popup_open(model.popup)),
      BoolUpdate("settings-open", model.settings_open),
      BoolUpdate("can-undo", can_undo(model)),
      BoolUpdate("can-redo", can_redo(model)),
      BoolUpdate(
        "can-delete-project",
        list.length(model.workspace.projects) > 1,
      ),
      BoolUpdate("show-hints", model.hints),
      BoolUpdate("agent-open", model.agent_open),
      BoolUpdate("project-selected", model.selected_project),
      BoolUpdate("project-dialog-open", model.project_dialog_open),
      TextUpdate("project-title", model.project.title),
      TextUpdate("project-path", model.project.path),
      BoolUpdate("context-open", model.context_open),
      IntUpdate("context-x", model.context_x),
      IntUpdate("context-y", model.context_y),
      BoolUpdate("mcp-enabled", model.mcp_enabled),
      TextUpdate("mcp-port-text", int.to_string(model.mcp_port)),
      TextUpdate("mcp-status", model.mcp_status),
      TextUpdate("pending-kind", pending_kind_key(model)),
      BoolUpdate("drop-active", model.drop_active),
      TextUpdate("drop-candidate", model.drop_candidate),
      ScalarIntUpdate("selection-count", list.length(model.selection)),
      BoolUpdate("dark-mode", is_dark_scheme(model.scheme)),
      TextUpdate("editor-font", model.font),
      IntUpdate("editor-font-size", model.font_size),
      ScalarIntUpdate("font-index", index_of(shell.fonts, model.font)),
      ScalarIntUpdate(
        "size-index",
        index_of(shell.sizes, int.to_string(model.font_size)),
      ),
      ScalarIntUpdate("scheme-index", scheme_index(model.scheme)),
      TextUpdate("form-title", title),
      BoolUpdate("context-align", model.context_align),
      BoolUpdate("nav-context-open", model.nav_context_open),
      BoolUpdate("nav-context-project", model.nav_kind == "project"),
      IntUpdate("code-scroll-y", code_scroll_y(model)),
      IntUpdate("code-jump-line", code_jump_line(model)),
      ScalarIntUpdate("code-jump-nonce", model.code_jump_nonce),
      BoolUpdate("completions-open", !list.is_empty(model.completions)),
      ScalarIntUpdate("completion-index", model.completion_index),
    ],
    theme_colors(model.scheme),
  )
}

fn tabs(model: State) -> List(TabItem) {
  list.filter_map(model.opened, fn(id) {
    case project.find_module(model.project, id) {
      Some(module) ->
        Ok(TabItem(module.id, module.name, module.id == model.active))
      None -> Error(Nil)
    }
  })
}

fn controls(model: State) -> List(ControlItem) {
  case active_form(model) {
    None -> []
    Some(form) ->
      list.map(campy_form.render_controls(form), fn(control) {
        let #(x, y, w, h) = campy_form.bounds(form, control)
        ControlItem(
          control.id,
          campy_form.kind_key(control.kind),
          control.text,
          x,
          y,
          w,
          h,
          control.enabled,
          control.visible,
          list.contains(model.selection, control.id),
          model.selected == Some(control.id),
          case control.kind {
            campy_form.Picture -> control.text
            _ -> ""
          },
          control_value(control),
          campy_form.transparency_of(form, control.id),
          campy_form.layout_of(form, campy_form.parent_of(form, control.id))
            != campy_form.Free,
          prop_bool(control, "checked"),
          prop(control, "placeholder-text"),
          prop_bool(control, "read-only"),
          prop_int(control, "minimum", 0),
          prop_int(control, "maximum", 100),
          prop_int(control, "current-index", 0),
          string.split(control.text, ",")
            |> list.map(string.trim)
            |> list.filter(fn(item) { item != "" }),
        )
      })
  }
}

// ---------------------------------------------------------------------------
// Inspector grid rows
// ---------------------------------------------------------------------------

// Properties tab: one row per property of the selection (common keys only
// when several components are selected), or the module window's properties
// when nothing is selected.
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
    False -> PropItem(..row, value: "", checked: False, index: -1)
  }
}

fn control_rows(form: Form, id: String) -> List(PropItem) {
  case campy_form.find_control(form, id) {
    None -> []
    Some(control) -> {
      let geometry = [
        number_row("x", "X", int.to_string(control.x)),
        number_row("y", "Y", int.to_string(control.y)),
        number_row("w", "W", int.to_string(control.width)),
        number_row("h", "H", int.to_string(control.height)),
      ]
      let picture = case control.kind {
        campy_form.Picture -> [
          open_row("picture", "Picture", control.text),
          number_row(
            "transparency",
            "Transp. %",
            int.to_string(campy_form.transparency_of(form, id)),
          ),
        ]
        _ -> []
      }
      let align = case form.layout {
        campy_form.Free -> [
          choice_row(
            "align",
            "Align",
            ["Free", "Top", "Bottom", "Left", "Right", "Client", "Fill"],
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
            "Layout",
            ["Free", "Column", "Row"],
            layout_index_of(campy_form.layout_of(form, id)),
          ),
          number_row(
            "border",
            "Border",
            int.to_string(campy_form.border_of(form, id)),
          ),
        ]
        False -> []
      }
      let color = case campy_form.color_of(form, id) {
        "" -> color_row("color", "Color", "")
        hex -> color_row("color", "Color", hex)
      }
      // Component properties from the CCL schema (Slint semantics): one row
      // per declared property, edited per its declared type.
      let schema =
        campy_ccl.properties(campy_form.kind_key(control.kind))
        |> list.map(fn(property: campy_ccl.Property) {
          let value =
            campy_form.control_prop(control, property.key, property.default)
          case property.kind {
            campy_ccl.Text -> text_row(property.key, property.label, value)
            campy_ccl.Number -> number_row(property.key, property.label, value)
            campy_ccl.Bool ->
              bool_row(property.key, property.label, value == "true")
          }
        })
      list.flatten([
        [
          text_row("name", "Name", control.name),
          text_row("text", "Text", control.text),
        ],
        schema,
        picture,
        geometry,
        [color],
        align,
        container,
        [
          bool_row("enabled", "Enabled", control.enabled),
          bool_row("visible", "Visible", control.visible),
        ],
      ])
    }
  }
}

fn control_event_rows(form: Form, id: String) -> List(PropItem) {
  case campy_form.find_control(form, id) {
    None -> []
    Some(control) ->
      campy_ccl.events(campy_form.kind_key(control.kind))
      |> list.map(fn(event: campy_ccl.Event) {
        PropItem(
          event.key,
          event.label,
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
      text_row("title", "Title", form.title),
      number_row("width", "Width", int.to_string(form.width)),
      number_row("height", "Height", int.to_string(form.height)),
      choice_row(
        "layout",
        "Layout",
        ["Free", "Column", "Row"],
        layout_index_of(form.layout),
      ),
      number_row(
        "border",
        "Border",
        int.to_string(campy_form.border_of(form, "")),
      ),
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

fn text_row(key: String, label: String, value: String) -> PropItem {
  PropItem(key, label, "text", value, False, 0, [], hint_of(key))
}

fn number_row(key: String, label: String, value: String) -> PropItem {
  PropItem(key, label, "number", value, False, 0, [], hint_of(key))
}

fn bool_row(key: String, label: String, checked: Bool) -> PropItem {
  PropItem(key, label, "bool", "", checked, 0, [], hint_of(key))
}

fn choice_row(
  key: String,
  label: String,
  options: List(String),
  index: Int,
) -> PropItem {
  PropItem(key, label, "choice", "", False, index, options, hint_of(key))
}

fn open_row(key: String, label: String, value: String) -> PropItem {
  PropItem(key, label, "picture", value, False, 0, [], hint_of(key))
}

fn color_row(key: String, label: String, value: String) -> PropItem {
  PropItem(key, label, "color", value, False, 0, [], hint_of(key))
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
    "placeholder-text" -> "Text when empty"
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
    CompletionItem(item.label, item.detail, item.insert)
  })
}

pub fn console_lines(model: State) -> List(String) {
  model.console
}

pub fn diagnostics(model: State) -> List(DiagItem) {
  list.map(model.diagnostics, fn(diagnostic) {
    let #(line, severity, message) = diagnostic
    DiagItem(line, severity, message)
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

fn code(model: State) -> List(LineItem) {
  case active_module(model) {
    None -> []
    Some(module) ->
      module.source
      |> string.split("\n")
      |> list.map(fn(line) {
        LineItem(
          list.map(syntax.tokenize(line), fn(token) {
            case token {
              syntax.Token(kind, text) -> TokenItem(text, token_kind(kind))
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

fn theme_colors(scheme: Scheme) -> List(Update) {
  let colors = case scheme {
    Light -> [
      #("theme-bg", "#f5f5f5"),
      #("theme-fg", "#202020"),
      #("theme-border", "#c8c8c8"),
      #("theme-accent", "#0067c0"),
      #("theme-tint", "#dce9f7"),
      #("theme-surface", "#ffffff"),
      #("theme-canvas", "#e6e6e6"),
      #("theme-grid", "#c6c6c6"),
      #("code-bg", "#ffffff"),
      #("code-comment", "#6a737d"),
      #("code-keyword", "#a626a4"),
      #("code-string", "#50a14f"),
      #("code-number", "#986801"),
      #("code-type", "#c18401"),
      #("code-punct", "#0184bc"),
      #("code-name", "#202020"),
    ]
    Solarized -> [
      #("theme-bg", "#002b36"),
      #("theme-fg", "#93a1a1"),
      #("theme-border", "#073642"),
      #("theme-accent", "#268bd2"),
      #("theme-tint", "#073642"),
      #("theme-surface", "#073642"),
      #("theme-canvas", "#001f27"),
      #("theme-grid", "#0a3a46"),
      #("code-bg", "#002b36"),
      #("code-comment", "#586e75"),
      #("code-keyword", "#859900"),
      #("code-string", "#2aa198"),
      #("code-number", "#d33682"),
      #("code-type", "#b58900"),
      #("code-punct", "#6c71c4"),
      #("code-name", "#93a1a1"),
    ]
    Dark -> [
      #("theme-bg", "#1e1e1e"),
      #("theme-fg", "#e6e6e6"),
      #("theme-border", "#3a3a3a"),
      #("theme-accent", "#0078d4"),
      #("theme-tint", "#1f3a5f"),
      #("theme-surface", "#20242c"),
      #("theme-canvas", "#14161a"),
      #("theme-grid", "#2f3540"),
      #("code-bg", "#282c34"),
      #("code-comment", "#7f848e"),
      #("code-keyword", "#c678dd"),
      #("code-string", "#98c379"),
      #("code-number", "#d19a66"),
      #("code-type", "#e5c07b"),
      #("code-punct", "#56b6c2"),
      #("code-name", "#abb2bf"),
    ]
  }
  list.map(colors, fn(entry) { ColorUpdate(entry.0, entry.1) })
}

// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------

pub fn projects_wire(items: List(ProjectItem)) -> List(bridge.WireValue) {
  list.map(items, fn(item) {
    bridge.WireStruct([
      #("id", bridge.WireText(item.id)),
      #("title", bridge.WireText(item.title)),
      #("active", bridge.WireBool(item.active)),
      #("icon", bridge.WireImage(item.icon)),
      #("has-icon", bridge.WireBool(item.has_icon)),
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

// ---------------------------------------------------------------------------
// Scalar diffing
// ---------------------------------------------------------------------------

pub fn diff(previous: List(Update), next: List(Update)) -> List(Update) {
  list.filter(next, fn(update) {
    case
      list.find(previous, fn(old) { update_name(old) == update_name(update) })
    {
      Ok(old) -> update_value(old) != update_value(update)
      Error(_) -> True
    }
  })
}

pub fn update_name(update: Update) -> String {
  case update {
    TextUpdate(name, _) -> name
    BoolUpdate(name, _) -> name
    IntUpdate(name, _) -> name
    ScalarIntUpdate(name, _) -> name
    ColorUpdate(name, _) -> name
  }
}

fn update_value(update: Update) -> String {
  case update {
    TextUpdate(_, value) -> "t" <> value
    BoolUpdate(_, value) -> "b" <> bool(value)
    IntUpdate(_, value) -> "i" <> int.to_string(value)
    ScalarIntUpdate(_, value) -> "i" <> int.to_string(value)
    ColorUpdate(_, value) -> "c" <> value
  }
}

// ---------------------------------------------------------------------------
// Static shell
// ---------------------------------------------------------------------------

pub fn to_slint(model: State) -> Result(String, String) {
  Ok(shell.source(
    "Campy IDE — " <> model.project.title,
    declarations(scalars(model)),
  ))
}

fn declarations(values: List(Update)) -> String {
  values |> list.map(declaration) |> string.concat
}

fn declaration(update: Update) -> String {
  case update {
    TextUpdate(name, value) ->
      "  in-out property <string> " <> name <> ": " <> quote(value) <> ";\n"
    BoolUpdate(name, value) ->
      "  in-out property <bool> " <> name <> ": " <> bool(value) <> ";\n"
    IntUpdate(name, value) ->
      "  in-out property <length> "
      <> name
      <> ": "
      <> int.to_string(value)
      <> "px;\n"
    ScalarIntUpdate(name, value) ->
      "  in-out property <int> "
      <> name
      <> ": "
      <> int.to_string(value)
      <> ";\n"
    ColorUpdate(name, value) ->
      "  in-out property <color> " <> name <> ": " <> value <> ";\n"
  }
}

fn pending_kind_key(model: State) -> String {
  case model.pending_kind {
    Some(kind) -> campy_form.kind_key(kind)
    None -> ""
  }
}

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

fn is_slint_tab(model: State) -> Bool {
  model.slint_tab
}

fn layout_is(form: Option(Form), layout: campy_form.Layout) -> Bool {
  case form {
    Some(value) -> value.layout == layout
    None -> False
  }
}

fn form_width(form: Option(Form)) -> Int {
  case form {
    Some(value) -> value.width
    None -> 0
  }
}

fn form_height(form: Option(Form)) -> Int {
  case form {
    Some(value) -> value.height
    None -> 0
  }
}

fn code_handler_label(model: State) -> String {
  case model.active_handler {
    Some(handler) -> handler
    None -> active_name(model)
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

// Scroll position that lands the jump target a few lines from the top.
fn code_scroll_y(model: State) -> Int {
  case model.code_jump {
    Some(line) -> int.max(0, { line - 3 } * { model.font_size + 6 })
    None -> 0
  }
}

fn code_jump_line(model: State) -> Int {
  case model.code_jump {
    Some(line) -> line
    None -> 0
  }
}

fn browser_items(model: State) -> List(BrowserItem) {
  case model.browser {
    Some(browser) ->
      list.map(browser.entries, fn(entry) {
        BrowserItem(entry.name, entry.is_dir)
      })
    None -> []
  }
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

fn window_x(model: State) -> Int {
  state.window_position(model).0
}

fn window_y(model: State) -> Int {
  state.window_position(model).1
}

fn form_border_size(model: State) -> Int {
  case active_form(model) {
    Some(form) -> campy_form.border_of(form, "")
    None -> 0
  }
}

fn scheme_index(scheme: Scheme) -> Int {
  case scheme {
    Dark -> 0
    Light -> 1
    Solarized -> 2
  }
}

fn bool(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
