import campy_bridge as bridge
import campy_ccl
import campy_form.{type Form}
import campy_form/preview.{quote}
import campy_form/project
import campy_form/syntax
import campy_ide/state.{
  type Popup, type Scheme, type State, CodeView, Dark, Edit, Editing, FormView,
  Light, NoPopup, OpenFile, PickPicture, PickProjectIcon, SaveAs, Solarized,
  View, active_form, active_module, active_name, can_redo, can_undo,
  is_events_tab, selected_align, selected_control, selection_label,
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
    arranged: Bool,
  )
}

pub type TokenItem {
  TokenItem(text: String, kind: String)
}

pub type LineItem {
  LineItem(tokens: List(TokenItem))
}

pub type Snapshot {
  Snapshot(
    scalars: List(Update),
    projects: List(ProjectItem),
    modules: List(ModuleItem),
    tabs: List(TabItem),
    controls: List(ControlItem),
    code: List(LineItem),
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
  )
}

const fonts = [
  "monospace", "DejaVu Sans Mono", "Liberation Mono", "Courier New",
  "Noto Sans Mono",
]

const sizes = ["11", "12", "13", "14", "16", "18", "20"]

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

fn scalars(model: State) -> List(Update) {
  let form = active_form(model)
  let selected = selected_control(model)
  let #(name, text, x, y, w, h, enabled, visible) = case selected {
    Some(control) -> #(
      control.name,
      control.text,
      int.to_string(control.x),
      int.to_string(control.y),
      int.to_string(control.width),
      int.to_string(control.height),
      control.enabled,
      control.visible,
    )
    None -> #("", "", "", "", "", "", False, False)
  }
  let #(title, form_w, form_h) = case form {
    Some(value) -> #(
      value.title,
      int.to_string(value.width),
      int.to_string(value.height),
    )
    None -> #("", "", "")
  }
  let #(event_label, event_handler, has_events) = case selected {
    Some(control) ->
      case campy_form.handler_name(control) {
        Some(handler) -> #(campy_form.event_label(control.kind), handler, True)
        None -> #("", "", False)
      }
    None -> #("", "", False)
  }
  let selected_kind = case selected {
    Some(control) -> campy_form.kind_key(control.kind)
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
      TextUpdate("selected-kind", selected_kind),
      TextUpdate("canvas-label", canvas_label(form)),
      TextUpdate("module-count", module_count_text(model)),
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
      BoolUpdate("code-editing", is_editing_code(model)),
      BoolUpdate("has-handler", is_some(model.active_handler)),
      TextUpdate("code-handler", code_handler_label(model)),
      TextUpdate("code-text", code_text(model)),
      IntUpdate("code-scroll", highlight_scroll(model)),
      IntUpdate("hl-top", highlight_top(model)),
      IntUpdate("hl-height", highlight_height(model)),
      IntUpdate("code-height", code_height(model)),
      TextUpdate("slint-source", slint_source),
      TextUpdate("console-text", state.console_text(model)),
      TextUpdate("popup-path", model.project.path),
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
      TextUpdate("project-module-count", module_count_text(model)),
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
      ScalarIntUpdate("layout-index", layout_index(form)),
      ScalarIntUpdate("container-layout-index", container_layout_index(model)),
      TextUpdate("insp-border", selected_border(model)),
      TextUpdate("form-border", form_border(model)),
      BoolUpdate("dark-mode", is_dark_scheme(model.scheme)),
      TextUpdate("editor-font", model.font),
      IntUpdate("editor-font-size", model.font_size),
      ScalarIntUpdate("font-index", index_of(fonts, model.font)),
      ScalarIntUpdate(
        "size-index",
        index_of(sizes, int.to_string(model.font_size)),
      ),
      ScalarIntUpdate("scheme-index", scheme_index(model.scheme)),
      ScalarIntUpdate("align-index", align_index(selected_align(model))),
      TextUpdate("insp-name", name),
      TextUpdate("insp-text", text),
      TextUpdate("insp-x", x),
      TextUpdate("insp-y", y),
      TextUpdate("insp-w", w),
      TextUpdate("insp-h", h),
      BoolUpdate("insp-enabled", enabled),
      BoolUpdate("insp-visible", visible),
      TextUpdate("form-title", title),
      TextUpdate("form-width", form_w),
      TextUpdate("form-height", form_h),
      TextUpdate("event-label", event_label),
      TextUpdate("event-handler", event_handler),
      BoolUpdate("has-events", has_events),
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
          campy_form.layout_of(form, campy_form.parent_of(form, control.id))
            != campy_form.Free,
        )
      })
  }
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
  Ok(
    "import { Button, CheckBox, ComboBox, LineEdit, ListView, Palette, ProgressIndicator, ScrollView, Slider, TextEdit } from \"std-widgets.slint\";\n"
    <> structs()
    <> components()
    <> "export component CampyPreview inherits Window {\n"
    <> "  title: "
    <> quote("Campy IDE — " <> model.project.title)
    <> ";\n"
    <> "  preferred-width: 1280px;\n"
    <> "  preferred-height: 860px;\n"
    <> "  min-width: 960px;\n"
    <> "  min-height: 640px;\n"
    <> "  in-out property <[ProjectItem]> project-items: [];\n"
    <> "  in-out property <[ModuleItem]> module-items: [];\n"
    <> "  in-out property <[TabItem]> tab-items: [];\n"
    <> "  in-out property <[ControlItem]> control-items: [];\n"
    <> "  in-out property <[LineItem]> code-lines: [];\n"
    <> "  in-out property <[PaletteItem]> palette-items: "
    <> palette_literal()
    <> ";\n"
    <> "  in-out property <bool> frame-tool: false;\n"
    <> "  in-out property <bool> shift-down: false;\n"
    <> "  in-out property <bool> ctrl-down: false;\n"
    <> "  in-out property <bool> marquee-active: false;\n"
    <> "  in-out property <length> marquee-x: 0px;\n"
    <> "  in-out property <length> marquee-y: 0px;\n"
    <> "  in-out property <length> marquee-w: 0px;\n"
    <> "  in-out property <length> marquee-h: 0px;\n"
    <> "  in-out property <bool> place-active: false;\n"
    <> "  in-out property <length> place-x: 0px;\n"
    <> "  in-out property <length> place-y: 0px;\n"
    <> "  in-out property <length> place-w: 0px;\n"
    <> "  in-out property <length> place-h: 0px;\n"
    <> "  in-out property <length> win-drag-x: 0px;\n"
    <> "  in-out property <length> win-drag-y: 0px;\n"
    <> "  in-out property <bool> win-moving: false;\n"
    <> "  in-out property <length> win-resize-dw: 0px;\n"
    <> "  in-out property <length> win-resize-dh: 0px;\n"
    <> "  in-out property <bool> win-resizing: false;\n"
    <> declarations(scalars(model))
    <> "  init => { Palette.color-scheme = dark-mode ? ColorScheme.dark : ColorScheme.light; }\n"
    <> "  changed dark-mode => { Palette.color-scheme = dark-mode ? ColorScheme.dark : ColorScheme.light; }\n"
    <> callbacks()
    <> "  forward-focus: key-handler;\n"
    <> "  key-handler := FocusScope {\n"
    <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
    <> keybindings()
    <> "    key-pressed(event) => {\n"
    <> "      if (event.text == Key.Shift) { root.shift-down = true; }\n"
    <> "      if (event.text == Key.Control) { root.ctrl-down = true; }\n"
    <> "      reject\n"
    <> "    }\n"
    <> "    key-released(event) => {\n"
    <> "      if (event.text == Key.Shift) { root.shift-down = false; }\n"
    <> "      if (event.text == Key.Control) { root.ctrl-down = false; }\n"
    <> "      reject\n"
    <> "    }\n"
    <> "    Rectangle { width: 100%; height: 100%; background: root.theme-bg; }\n"
    <> "    VerticalLayout { width: 100%; height: 100%; spacing: 0px;\n"
    <> menu_bar()
    <> main_area()
    <> "      Rectangle { height: 1px; background: theme-border; }\n"
    <> status_bar()
    <> "\n    }\n"
    <> settings_overlay()
    <> agent_overlay()
    <> project_dialog_overlay()
    <> popup_overlay()
    <> "  }\n"
    <> "}\n",
  )
}

fn structs() -> String {
  "struct ProjectItem { id: string, title: string, active: bool, icon: image, has-icon: bool }\n"
  <> "struct ModuleItem { id: string, name: string, active: bool }\n"
  <> "struct TabItem { id: string, name: string, active: bool }\n"
  <> "struct ControlItem { id: string, kind: string, text: string, x: length, y: length, w: length, h: length, enabled: bool, visible: bool, selected: bool, primary: bool, picture: image, value: float, arranged: bool }\n"
  <> "struct TokenItem { text: string, kind: string }\n"
  <> "struct LineItem { tokens: [TokenItem] }\n"
  <> "struct PaletteItem { kind: string, icon: string, label: string }\n"
}

fn components() -> String {
  "component DottedFrame inherits Rectangle {\n"
  <> "  in property <color> dot-color: #0078d4;\n"
  <> "  for i in "
  <> dot_range()
  <> ": Rectangle { x: (parent.width - 2px) * i / 24; y: 0; width: 2px; height: 2px; background: dot-color; }\n"
  <> "  for i in "
  <> dot_range()
  <> ": Rectangle { x: (parent.width - 2px) * i / 24; y: parent.height - 2px; width: 2px; height: 2px; background: dot-color; }\n"
  <> "  for i in "
  <> dot_range()
  <> ": Rectangle { x: 0; y: (parent.height - 2px) * i / 24; width: 2px; height: 2px; background: dot-color; }\n"
  <> "  for i in "
  <> dot_range()
  <> ": Rectangle { x: parent.width - 2px; y: (parent.height - 2px) * i / 24; width: 2px; height: 2px; background: dot-color; }\n"
  <> "}\n\n"
  <> "component ResizeHandle inherits Rectangle {\n"
  <> "  in property <string> mode;\n"
  <> "  in property <color> accent;\n"
  <> "  callback gesture-start();\n"
  <> "  callback gesture-track(length, length);\n"
  <> "  callback gesture-finish();\n"
  <> "  width: 10px; height: 10px;\n"
  <> "  background: accent;\n"
  <> "  border-radius: 3px;\n"
  <> "  TouchArea {\n"
  <> "    mouse-cursor: mode == \"nw\" || mode == \"se\" ? MouseCursor.nwse-resize : mode == \"ne\" || mode == \"sw\" ? MouseCursor.nesw-resize : mode == \"n\" || mode == \"s\" ? MouseCursor.ns-resize : MouseCursor.ew-resize;\n"
  <> "    pointer-event(event) => {\n"
  <> "      if (event.kind == PointerEventKind.down) { root.gesture-start(); }\n"
  <> "      if (event.kind == PointerEventKind.up) { root.gesture-finish(); }\n"
  <> "    }\n"
  <> "    moved => {\n"
  <> "      if (self.pressed) {\n"
  <> "        root.gesture-track(self.mouse-x - self.pressed-x, self.mouse-y - self.pressed-y);\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
  <> "}\n\n"
  <> "component ControlView inherits Rectangle {\n"
  <> "  in property <ControlItem> data;\n"
  <> "  in property <bool> designing: false;\n"
  <> "  in property <bool> free-layout: false;\n"
  <> "  in property <color> theme-fg;\n"
  <> "  in property <color> theme-accent;\n"
  <> "  in property <color> theme-border;\n"
  <> "  in property <color> theme-surface;\n"
  <> "  in property <bool> additive: false;\n"
  <> "  in property <string> drop-candidate: \"\";\n"
  <> "  callback select(string);\n"
  <> "  callback toggle-select(string);\n"
  <> "  callback drag-start();\n"
  <> "  callback drag-over-x(int);\n"
  <> "  callback drag-over-y(int);\n"
  <> "  callback move-x(int);\n"
  <> "  callback move-y(int);\n"
  <> "  callback resize-left(int);\n"
  <> "  callback resize-right(int);\n"
  <> "  callback resize-top(int);\n"
  <> "  callback resize-bottom(int);\n"
  <> "  callback gesture-start();\n"
  <> "  callback gesture-end();\n"
  <> "  callback context-menu(string);\n"
  <> "  property <length> drag-x: 0px;\n"
  <> "  property <length> drag-y: 0px;\n"
  <> "  property <string> resize-mode: \"\";\n"
  <> "  property <length> resize-dw: 0px;\n"
  <> "  property <length> resize-dh: 0px;\n"
  <> "  property <bool> resizing: false;\n"
  <> "  property <bool> west: resize-mode == \"w\" || resize-mode == \"nw\" || resize-mode == \"sw\";\n"
  <> "  property <bool> east: resize-mode == \"e\" || resize-mode == \"ne\" || resize-mode == \"se\";\n"
  <> "  property <bool> north: resize-mode == \"n\" || resize-mode == \"nw\" || resize-mode == \"ne\";\n"
  <> "  property <bool> south: resize-mode == \"s\" || resize-mode == \"sw\" || resize-mode == \"se\";\n"
  <> "  content := Rectangle {\n"
  <> "    clip: true;\n"
  <> "    x: free-layout ? drag-x : 0px;\n"
  <> "    y: free-layout ? drag-y : 0px;\n"
  <> "    width: free-layout ? data.w : parent.width;\n"
  <> "    height: free-layout ? data.h : parent.height;\n"
  <> "    border-width: data.selected ? 2px : data.id == drop-candidate ? 2px : (data.kind == \"label\" || data.kind == \"picture\" || data.kind == \"checkbox\" || data.kind == \"radio\" ? 0px : 1px);\n"
  <> "    border-color: data.selected ? theme-accent : data.id == drop-candidate ? #f0c040 : (data.kind == \"panel\" ? theme-border : #6a6a6a);\n"
  <> "    background: data.kind == \"panel\" || data.kind == \"group\" ? theme-surface : transparent;\n"
  <> "    border-radius: data.kind == \"panel\" ? 4px : 0px;\n"
  <> "    opacity: data.visible ? 1 : 0.35;\n"
  <> "    if data.kind == \"label\": Text { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; color: theme-fg; vertical-alignment: center; }\n"
  <> "    if data.kind == \"edit\": LineEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; }\n"
  <> "    if data.kind == \"memo\": TextEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; read-only: true; }\n"
  <> "    if data.kind == \"button\": Button { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; }\n"
  <> "    if data.kind == \"checkbox\": CheckBox { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; }\n"
  <> "    if data.kind == \"radio\": Rectangle { x: 0; y: (parent.height - 18px) / 2; width: 18px; height: 18px; border-radius: 9px; border-width: 1px; border-color: theme-fg; background: transparent; }\n"
  <> "    if data.kind == \"radio\": Rectangle { x: 5px; y: (parent.height - 8px) / 2; width: 8px; height: 8px; border-radius: 4px; background: theme-accent; }\n"
  <> "    if data.kind == \"radio\": Text { x: 26px; y: 0; height: parent.height; text: data.text; color: theme-fg; vertical-alignment: center; }\n"
  <> "    if data.kind == \"combo\": ComboBox { x: 0; y: 0; width: parent.width; height: parent.height; model: [\"First\", \"Second\", \"Third\"]; current-index: 0; enabled: data.enabled; }\n"
  <> "    if data.kind == \"list\": ListView { x: 0; y: 0; width: parent.width; height: parent.height;\n"
  <> "      for item in [\"First item\", \"Second item\", \"Third item\", \"Fourth item\", \"Fifth item\"]: Rectangle { height: 26px;\n"
  <> "        Text { x: 8px; y: 0; height: parent.height; text: item; color: theme-fg; vertical-alignment: center; }\n"
  <> "      }\n"
  <> "    }\n"
  <> "    if data.kind == \"slider\": Slider { x: 0; y: 0; width: parent.width; height: parent.height; minimum: 0.0; maximum: 100.0; value: data.value; enabled: data.enabled; }\n"
  <> "    if data.kind == \"progress\": ProgressIndicator { x: 0; y: (parent.height - 6px) / 2; width: parent.width; height: 6px; progress: data.value / 100.0; }\n"
  <> "    if data.kind == \"picture\": Image { x: 0; y: 0; width: parent.width; height: parent.height; source: data.picture; image-fit: contain; }\n"
  <> "    if data.kind == \"panel\" || data.kind == \"group\": Text { x: 8px; y: 6px; text: data.text; color: theme-fg; font-weight: 600; }\n"
  <> "    if data.kind == \"menu\": Rectangle { x: 0; y: 0; width: parent.width; height: parent.height; background: theme-surface; border-width: 1px; border-color: theme-border; border-radius: 3px;\n"
  <> "      Text { x: 10px; y: 0; height: parent.height; text: data.text; color: theme-fg; vertical-alignment: center; }\n"
  <> "      Text { x: parent.width - 20px; y: 0; height: parent.height; text: \"▾\"; color: theme-fg; vertical-alignment: center; }\n"
  <> "    }\n"
  <> "  }\n"
  <> "  if designing && free-layout: TouchArea {\n"
  <> "    pointer-event(event) => {\n"
  <> "      if (event.kind == PointerEventKind.down && event.button == PointerEventButton.left) { root.gesture-start(); root.drag-start(); if (root.additive) { root.toggle-select(data.id); } else { root.select(data.id); } }\n"
  <> "      if (event.kind == PointerEventKind.down && event.button == PointerEventButton.right) { root.context-menu(data.id); }\n"
  <> "      if (event.kind == PointerEventKind.up && event.button == PointerEventButton.left) {\n"
  <> "        if (drag-x != 0px || drag-y != 0px) {\n"
  <> "          root.move-x(round(drag-x / 1px));\n"
  <> "          root.move-y(round(drag-y / 1px));\n"
  <> "        }\n"
  <> "        drag-x = 0px; drag-y = 0px;\n"
  <> "        root.gesture-end();\n"
  <> "      }\n"
  <> "    }\n"
  <> "    moved => {\n"
  <> "      if (self.pressed) {\n"
  <> "        drag-x = self.mouse-x - self.pressed-x;\n"
  <> "        drag-y = self.mouse-y - self.pressed-y;\n"
  <> "        root.drag-over-x(round((data.x + drag-x + data.w / 2) / 1px));\n"
  <> "        root.drag-over-y(round((data.y + drag-y + data.h / 2) / 1px));\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
  <> "  if designing && !free-layout: TouchArea { clicked => { root.select(data.id); } pointer-event(event) => { if (event.kind == PointerEventKind.down && event.button == PointerEventButton.right) { root.context-menu(data.id); } } }\n"
  <> "  if designing && free-layout && resizing: Rectangle {\n"
  <> "    x: west ? resize-dw : 0px;\n"
  <> "    y: north ? resize-dh : 0px;\n"
  <> "    width: max(1px, data.w - (west ? resize-dw : 0px) + (east ? resize-dw : 0px));\n"
  <> "    height: max(1px, data.h - (north ? resize-dh : 0px) + (south ? resize-dh : 0px));\n"
  <> "    border-width: 1px; border-color: theme-accent; background: transparent;\n"
  <> "  }\n"
  <> "  if designing && free-layout && data.primary: Rectangle {\n"
  <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "    for mode in [\"nw\", \"n\", \"ne\", \"w\", \"e\", \"sw\", \"s\", \"se\"]: ResizeHandle {\n"
  <> "      mode: mode;\n"
  <> "      accent: theme-accent;\n"
  <> "      x: mode == \"nw\" || mode == \"w\" || mode == \"sw\" ? -5px : mode == \"n\" || mode == \"s\" ? (root.width - 10px) / 2 : root.width - 5px;\n"
  <> "      y: mode == \"nw\" || mode == \"n\" || mode == \"ne\" ? -5px : mode == \"w\" || mode == \"e\" ? (root.height - 10px) / 2 : root.height - 5px;\n"
  <> "      gesture-start() => {\n"
  <> "        root.resizing = true;\n"
  <> "        root.resize-mode = mode;\n"
  <> "        root.resize-dw = 0px;\n"
  <> "        root.resize-dh = 0px;\n"
  <> "        root.gesture-start();\n"
  <> "      }\n"
  <> "      gesture-track(dx, dy) => {\n"
  <> "        if (root.resizing) {\n"
  <> "          root.resize-dw = dx;\n"
  <> "          root.resize-dh = dy;\n"
  <> "        }\n"
  <> "      }\n"
  <> "      gesture-finish() => {\n"
  <> "        if (root.resizing) {\n"
  <> "          if (root.resize-mode == \"w\" || root.resize-mode == \"nw\" || root.resize-mode == \"sw\") {\n"
  <> "            root.resize-left(round(root.resize-dw / 1px));\n"
  <> "          }\n"
  <> "          if (root.resize-mode == \"e\" || root.resize-mode == \"ne\" || root.resize-mode == \"se\") {\n"
  <> "            root.resize-right(round(root.resize-dw / 1px));\n"
  <> "          }\n"
  <> "          if (root.resize-mode == \"n\" || root.resize-mode == \"nw\" || root.resize-mode == \"ne\") {\n"
  <> "            root.resize-top(round(root.resize-dh / 1px));\n"
  <> "          }\n"
  <> "          if (root.resize-mode == \"s\" || root.resize-mode == \"sw\" || root.resize-mode == \"se\") {\n"
  <> "            root.resize-bottom(round(root.resize-dh / 1px));\n"
  <> "          }\n"
  <> "          root.resizing = false;\n"
  <> "          root.resize-dw = 0px;\n"
  <> "          root.resize-dh = 0px;\n"
  <> "          root.gesture-end();\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
  <> "}\n"
}

fn palette_literal() -> String {
  "["
  <> string.join(
    list.map(campy_ccl.all(), fn(component) {
      "{ kind: "
      <> quote(component.key)
      <> ", icon: "
      <> quote(component.icon)
      <> ", label: "
      <> quote(component.label)
      <> " }"
    }),
    ", ",
  )
  <> "]"
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

fn callbacks() -> String {
  "  callback file-new();\n"
  <> "  callback file-new-module();\n"
  <> "  callback file-open();\n"
  <> "  callback file-save();\n"
  <> "  callback file-save-as();\n"
  <> "  callback file-quit();\n"
  <> "  callback run-app();\n"
  <> "  callback update-app();\n"
  <> "  callback reload-code();\n"
  <> "  callback stop-app();\n"
  <> "  callback open-module(string);\n"
  <> "  callback tab-module(string);\n"
  <> "  callback close-module(string);\n"
  <> "  callback new-module();\n"
  <> "  callback switch-project(string);\n"
  <> "  callback delete-project();\n"
  <> "  callback toggle-view();\n"
  <> "  callback view-form();\n"
  <> "  callback view-code();\n"
  <> "  callback show-ui();\n"
  <> "  callback show-slint();\n"
  <> "  callback console-input(string);\n"
  <> "  callback clear-console();\n"
  <> "  callback window-move-x(int);\n"
  <> "  callback window-move-y(int);\n"
  <> "  callback window-resize-w(int);\n"
  <> "  callback window-resize-h(int);\n"
  <> "  callback add-component(string);\n"
  <> "  callback copy-component();\n"
  <> "  callback cut-component();\n"
  <> "  callback paste-component();\n"
  <> "  callback undo();\n"
  <> "  callback redo();\n"
  <> "  callback select(string);\n"
  <> "  callback field-name(string);\n"
  <> "  callback field-text(string);\n"
  <> "  callback field-x(string);\n"
  <> "  callback field-y(string);\n"
  <> "  callback field-w(string);\n"
  <> "  callback field-h(string);\n"
  <> "  callback toggle-enabled(bool);\n"
  <> "  callback toggle-visible(bool);\n"
  <> "  callback field-title(string);\n"
  <> "  callback field-width(string);\n"
  <> "  callback field-height(string);\n"
  <> "  callback tab-properties();\n"
  <> "  callback tab-events();\n"
  <> "  callback edit-event(string);\n"
  <> "  callback delete-selected();\n"
  <> "  callback toggle-select(string);\n"
  <> "  callback drag-start();\n"
  <> "  callback drag-over-x(int);\n"
  <> "  callback drag-over-y(int);\n"
  <> "  callback rect-x(int);\n"
  <> "  callback rect-y(int);\n"
  <> "  callback rect-w(int);\n"
  <> "  callback rect-h(int);\n"
  <> "  callback frame-apply();\n"
  <> "  callback place-apply();\n"
  <> "  callback cancel-place();\n"
  <> "  callback toggle-hints(bool);\n"
  <> "  callback open-agent();\n"
  <> "  callback open-project-dialog();\n"
  <> "  callback close-project-dialog();\n"
  <> "  callback dialog-new-project();\n"
  <> "  callback dialog-open-project();\n"
  <> "  callback field-project-title(string);\n"
  <> "  callback field-border(string);\n"
  <> "  callback context-menu(string);\n"
  <> "  callback close-context-menu();\n"
  <> "  callback context-copy();\n"
  <> "  callback context-cut();\n"
  <> "  callback context-paste();\n"
  <> "  callback context-delete();\n"
  <> "  callback close-agent();\n"
  <> "  callback toggle-mcp(bool);\n"
  <> "  callback mcp-port(string);\n"
  <> "  callback editor-view();\n"
  <> "  callback editor-edit();\n"
  <> "  callback code-apply(string);\n"
  <> "  callback set-align(string);\n"
  <> "  callback set-layout(string);\n"
  <> "  callback set-container-layout(string);\n"
  <> "  callback set-layout-free();\n"
  <> "  callback set-layout-column();\n"
  <> "  callback set-layout-row();\n"
  <> "  callback move-x(int);\n"
  <> "  callback move-y(int);\n"
  <> "  callback resize-left(int);\n"
  <> "  callback resize-right(int);\n"
  <> "  callback resize-top(int);\n"
  <> "  callback resize-bottom(int);\n"
  <> "  callback gesture-start();\n"
  <> "  callback gesture-end();\n"
  <> "  callback browse-picture();\n"
  <> "  callback browse-project-icon();\n"
  <> "  callback clear-project-icon();\n"
  <> "  callback open-settings();\n"
  <> "  callback close-settings();\n"
  <> "  callback font-selected(string);\n"
  <> "  callback font-size-selected(string);\n"
  <> "  callback scheme-selected(string);\n"
  <> "  callback popup-accept(string);\n"
  <> "  callback file-cancel();\n"
}

fn keybindings() -> String {
  "    KeyBinding { keys: @keys(Control + Z); activated => { root.undo(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + Shift + Z); activated => { root.redo(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + Y); activated => { root.redo(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + C); activated => { root.copy-component(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + X); activated => { root.cut-component(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + V); activated => { root.paste-component(); } }\n"
  <> "    KeyBinding { keys: @keys(Delete); enabled: root.has-selection; activated => { root.delete-selected(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + N); activated => { root.file-new(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + Shift + N); activated => { root.file-new-module(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + O); activated => { root.file-open(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + S); activated => { root.file-save(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + Shift + S); activated => { root.file-save-as(); } }\n"
  <> "    KeyBinding { keys: @keys(Control + Q); activated => { root.file-quit(); } }\n"
  <> "    KeyBinding { keys: @keys(F5); activated => { root.run-app(); } }\n"
  <> "    KeyBinding { keys: @keys(F6); activated => { root.reload-code(); } }\n"
  <> "    KeyBinding { keys: @keys(F7); activated => { root.update-app(); } }\n"
  <> "    KeyBinding { keys: @keys(Shift + F5); activated => { root.stop-app(); } }\n"
  <> "    KeyBinding { keys: @keys(Escape); activated => { root.close-settings(); root.file-cancel(); root.cancel-place(); } }\n"
}

fn menu_bar() -> String {
  "    HorizontalLayout {\n"
  <> "      height: 46px; padding: 8px; spacing: 6px;\n"
  <> "      file-menu := ContextMenuArea { width: 58px; height: 32px;\n"
  <> "        Button { text: \"File\"; clicked => { file-menu.show({ x: 0px, y: 32px }); } "
  <> hint("File menu: new, open, save")
  <> " }\n"
  <> "        Menu {\n"
  <> "          MenuItem { title: \"New project    Ctrl+N\"; activated => { root.file-new(); } }\n"
  <> "          MenuItem { title: \"New module    Ctrl+Shift+N\"; activated => { root.file-new-module(); } }\n"
  <> "          MenuSeparator { }\n"
  <> "          MenuItem { title: \"Open…    Ctrl+O\"; activated => { root.file-open(); } }\n"
  <> "          MenuItem { title: \"Save    Ctrl+S\"; activated => { root.file-save(); } }\n"
  <> "          MenuItem { title: \"Save As…    Ctrl+Shift+S\"; activated => { root.file-save-as(); } }\n"
  <> "          MenuSeparator { }\n"
  <> "          MenuItem { title: \"Quit    Ctrl+Q\"; activated => { root.file-quit(); } }\n"
  <> "        }\n"
  <> "      }\n"
  <> "      edit-menu := ContextMenuArea { width: 58px; height: 32px;\n"
  <> "        Button { text: \"Edit\"; clicked => { edit-menu.show({ x: 0px, y: 32px }); } "
  <> hint("Edit menu: undo/redo, clipboard, delete")
  <> " }\n"
  <> "        Menu {\n"
  <> "          MenuItem { title: \"Undo    Ctrl+Z\"; enabled: root.can-undo; activated => { root.undo(); } }\n"
  <> "          MenuItem { title: \"Redo    Ctrl+Shift+Z\"; enabled: root.can-redo; activated => { root.redo(); } }\n"
  <> "          MenuSeparator { }\n"
  <> "          MenuItem { title: \"Copy component    Ctrl+C\"; activated => { root.copy-component(); } }\n"
  <> "          MenuItem { title: \"Cut component    Ctrl+X\"; activated => { root.cut-component(); } }\n"
  <> "          MenuItem { title: \"Paste component    Ctrl+V\"; activated => { root.paste-component(); } }\n"
  <> "          MenuSeparator { }\n"
  <> "          MenuItem { title: \"Delete component    Del\"; activated => { root.delete-selected(); } }\n"
  <> "          MenuSeparator { }\n"
  <> "          MenuItem { title: \"Update running app    F7\"; activated => { root.update-app(); } }\n"
  <> "          MenuItem { title: \"Reload Campy code    F6\"; activated => { root.reload-code(); } }\n"
  <> "        }\n"
  <> "      }\n"
  <> "      settings-menu := ContextMenuArea { width: 90px; height: 32px;\n"
  <> "        Button { text: \"Settings\"; clicked => { settings-menu.show({ x: 0px, y: 32px }); } "
  <> hint("Settings: editor and agent")
  <> " }\n"
  <> "        Menu {\n"
  <> "          MenuItem { title: \"Editor…\"; activated => { root.open-settings(); } }\n"
  <> "          MenuItem { title: \"Agent…\"; activated => { root.open-agent(); } }\n"
  <> "        }\n"
  <> "      }\n"
  <> "      Button { text: root.frame-tool ? \"▭\" : \"↖\"; width: 40px; height: 32px; primary: root.frame-tool; clicked => { root.frame-tool = !root.frame-tool; } "
  <> hint("Component selector: arrow selects, box draws a selection frame")
  <> " }\n"
  <> "      ScrollView { horizontal-stretch: 1; height: 42px;\n"
  <> "        HorizontalLayout { spacing: 4px; padding: 3px;\n"
  <> "          for item in root.palette-items: Rectangle {\n"
  <> "            width: 40px; height: 32px; border-width: 1px; border-color: root.theme-border; border-radius: 4px;\n"
  <> "            background: item.kind == root.pending-kind ? root.theme-tint : transparent;\n"
  <> "            Text { text: item.icon; color: root.theme-fg; horizontal-alignment: center; vertical-alignment: center; font-size: 16px; }\n"
  <> "            TouchArea { clicked => { key-handler.focus(); root.add-component(item.kind); } }\n"
  <> "            if root.show-hints: Tooltip { text: @markdown(\"{item.label}\"); }\n"
  <> "          }\n"
  <> "        }\n"
  <> "      }\n"
  <> "      Button { text: \"▶ Run\"; primary: true; enabled: !root.running; clicked => { root.run-app(); } "
  <> hint("Run the active module (F5)")
  <> " }\n"
  <> "      Button { text: \"■ Stop\"; enabled: root.running; clicked => { root.stop-app(); } "
  <> hint("Stop the running app (Shift+F5)")
  <> " }\n"
  <> "    }\n"
  <> "    Rectangle { height: 1px; background: root.theme-border; }\n"
}

fn main_area() -> String {
  "    HorizontalLayout { spacing: 0px; vertical-stretch: 1;\n"
  <> navigator()
  <> "      Rectangle { width: 1px; background: root.theme-border; }\n"
  <> centre()
  <> "      Rectangle { width: 1px; background: root.theme-border; }\n"
  <> right_pane()
  <> "    }\n"
}

fn navigator() -> String {
  "      VerticalLayout { width: 190px; spacing: 4px; padding: 8px;\n"
  <> "        HorizontalLayout { height: 28px; spacing: 4px;\n"
  <> "          Text { text: \"Projects\"; font-weight: 600; color: root.theme-fg; vertical-alignment: center; }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "          Button { text: \"+\"; width: 26px; height: 24px; clicked => { root.open-project-dialog(); } "
  <> hint("Add a project (new or existing)")
  <> " }\n"
  <> "          Rectangle { width: 26px; height: 24px; border-width: 1px; border-color: root.theme-border; border-radius: 4px; background: ws-trash.has-hover && root.can-delete-project ? root.theme-tint : transparent; opacity: root.can-delete-project ? 1 : 0.4;\n"
  <> "            ws-trash := TouchArea { enabled: root.can-delete-project; clicked => { root.delete-project(); } }\n"
  <> "            Path { x: (parent.width - 12px) / 2; y: (parent.height - 14px) / 2; width: 12px; height: 14px; stroke: root.theme-fg; stroke-width: 1.1px; fill: transparent;\n"
  <> "              commands: \"M 1 3 L 11 3 M 4 3 L 4 1 L 8 1 L 8 3 M 2 3 L 3 13 L 9 13 L 10 3 M 4.5 6 L 4.5 10 M 7.5 6 L 7.5 10\";\n"
  <> "            }\n"
  <> "            "
  <> hint("Delete the active project from the workspace")
  <> "\n"
  <> "          }\n"
  <> "        }\n"
  <> "        ListView { height: 110px;\n"
  <> "          for project in root.project-items: ContextMenuArea { width: 100%; height: 30px;\n"
  <> "            Rectangle { height: 30px;\n"
  <> "              background: project.active ? root.theme-tint : transparent;\n"
  <> "              HorizontalLayout { padding-left: 8px; padding-right: 8px; spacing: 6px;\n"
  <> "                if project.has-icon: Image { width: 18px; height: 18px; source: project.icon; image-fit: contain; }\n"
  <> "                if !project.has-icon: Text { text: \"▤\"; width: 18px; height: 18px; vertical-alignment: center; horizontal-alignment: center; color: root.theme-fg; }\n"
  <> "                Text { text: (project.active ? \"● \" : \"\") + project.title; vertical-alignment: center; color: root.theme-fg; overflow: elide; }\n"
  <> "              }\n"
  <> "              TouchArea { clicked => { root.switch-project(project.id); } }\n"
  <> "              "
  <> hint("Switch to this project; right-click for project actions")
  <> "\n"
  <> "            }\n"
  <> "            Menu {\n"
  <> "              MenuItem { title: \"Select project\"; activated => { root.switch-project(project.id); } }\n"
  <> "              MenuItem { title: \"New / open project…\"; activated => { root.open-project-dialog(); } }\n"
  <> "              MenuItem { title: \"Delete from workspace\"; enabled: project.active && root.can-delete-project; activated => { root.delete-project(); } }\n"
  <> "            }\n"
  <> "          }\n"
  <> "        }\n"
  <> "        Rectangle { height: 1px; background: root.theme-border; }\n"
  <> "        HorizontalLayout { height: 28px; spacing: 4px;\n"
  <> "          Text { text: \"Modules\"; font-weight: 600; color: root.theme-fg; vertical-alignment: center; }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "          Button { text: \"+\"; width: 30px; height: 26px; clicked => { root.new-module(); } "
  <> hint("Create a new module")
  <> " }\n"
  <> "        }\n"
  <> "        ListView { vertical-stretch: 1;\n"
  <> "          for module in root.module-items: ContextMenuArea { width: 100%; height: 32px;\n"
  <> "            Rectangle { height: 32px;\n"
  <> "              background: module.active ? root.theme-tint : transparent;\n"
  <> "              HorizontalLayout { padding-left: 8px; padding-right: 8px;\n"
  <> "                Text { text: (module.active ? \"● \" : \"\") + module.name; vertical-alignment: center; color: root.theme-fg; overflow: elide; }\n"
  <> "              }\n"
  <> "              TouchArea { clicked => { root.open-module(module.id); } }\n"
  <> "              "
  <> hint("Open this module; right-click for module actions")
  <> "\n"
  <> "            }\n"
  <> "            Menu {\n"
  <> "              MenuItem { title: \"Open module\"; activated => { root.open-module(module.id); } }\n"
  <> "              MenuItem { title: \"Close tab\"; activated => { root.close-module(module.id); } }\n"
  <> "            }\n"
  <> "          }\n"
  <> "        }\n"
  <> "        Text { text: root.module-count; color: root.theme-fg; }\n"
  <> "      }\n"
}

fn centre() -> String {
  "      VerticalLayout { horizontal-stretch: 1; max-width: 4000px; spacing: 0px;\n"
  <> "        HorizontalLayout { height: 36px; spacing: 2px; padding-left: 4px; padding-right: 4px;\n"
  <> "          for tab in root.tab-items: VerticalLayout { width: 140px;\n"
  <> "            HorizontalLayout { height: 32px; spacing: 0px;\n"
  <> "              Button { text: tab.name; horizontal-stretch: 1; clicked => { root.tab-module(tab.id); } "
  <> hint("Open this module")
  <> " }\n"
  <> "              Button { text: \"×\"; width: 26px; clicked => { root.close-module(tab.id); } "
  <> hint("Close this tab")
  <> " }\n"
  <> "            }\n"
  <> "            Rectangle { height: 2px; background: tab.active ? root.theme-accent : transparent; }\n"
  <> "          }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "          Button { text: root.code-view ? \"▦ Form editor\" : \"⌨ Handler code\"; primary: true; height: 32px; clicked => { root.toggle-view(); } "
  <> hint("Switch between the form editor and handler code")
  <> " }\n"
  <> "        }\n"
  <> "        Rectangle { height: 1px; background: root.theme-border; }\n"
  <> "        Rectangle { horizontal-stretch: 1; vertical-stretch: 1;\n"
  <> form_editor()
  <> code_view()
  <> editor_view()
  <> "        }\n"
  <> "        Rectangle { height: 1px; background: root.theme-border; }\n"
  <> console_pane()
  <> "      }\n"
}

fn console_pane() -> String {
  "        Rectangle { height: 170px; background: root.code-bg;\n"
  <> "          VerticalLayout { spacing: 0px;\n"
  <> "            HorizontalLayout { height: 28px; padding-left: 10px; padding-right: 8px; spacing: 6px;\n"
  <> "              Text { text: \"Console\"; color: root.code-name; font-weight: 600; vertical-alignment: center; }\n"
  <> "              Text { text: root.running ? \"running\" : \"stopped\"; color: root.code-comment; vertical-alignment: center; }\n"
  <> "              Rectangle { horizontal-stretch: 1; }\n"
  <> "              Button { text: \"Clear\"; clicked => { root.clear-console(); } "
  <> hint("Clear the console output")
  <> " }\n"
  <> "            }\n"
  <> "            TextEdit { text: root.console-text; read-only: true; vertical-stretch: 1; font-family: root.editor-font; font-size: root.editor-font-size; }\n"
  <> "            HorizontalLayout { height: 36px; padding: 4px; spacing: 6px;\n"
  <> "              console-entry := LineEdit { placeholder-text: \"Send input to the running app…\"; horizontal-stretch: 1; accepted(text) => { root.console-input(text); console-entry.text = \"\"; } }\n"
  <> "              Button { text: \"Send\"; primary: true; clicked => { root.console-input(console-entry.text); console-entry.text = \"\"; } "
  <> hint("Send this line to the running app")
  <> " }\n"
  <> "            }\n"
  <> "          }\n"
  <> "        }\n"
}

// The form editor: bottom tabs switch between the actual design and the
// generated Slint source.
fn form_editor() -> String {
  "          if !root.code-view: VerticalLayout { spacing: 0px;\n"
  <> "            Rectangle { horizontal-stretch: 1; vertical-stretch: 1;\n"
  <> free_canvas()
  <> column_canvas()
  <> row_canvas()
  <> slint_source_view()
  <> "            }\n"
  <> "            Rectangle { height: 1px; background: root.theme-border; }\n"
  <> "            HorizontalLayout { height: 34px; spacing: 4px; padding-left: 4px;\n"
  <> "              Button { text: \"▦ UI (actual)\"; primary: !root.slint-tab; height: 30px; clicked => { root.show-ui(); } "
  <> hint("Designer canvas")
  <> " }\n"
  <> "              Button { text: \"⌨ Code (Slint file)\"; primary: root.slint-tab; height: 30px; clicked => { root.show-slint(); } "
  <> hint("Generated Slint source")
  <> " }\n"
  <> "              Rectangle { horizontal-stretch: 1; }\n"
  <> "            }\n"
  <> "          }\n"
}

fn slint_source_view() -> String {
  "            if root.slint-tab: Rectangle { width: 100%; height: 100%; background: root.code-bg;\n"
  <> "              VerticalLayout { spacing: 0px;\n"
  <> "                HorizontalLayout { height: 32px; padding-left: 10px; spacing: 6px;\n"
  <> "                  Text { text: \"Generated Slint (read-only)\"; color: root.code-comment; vertical-alignment: center; }\n"
  <> "                  Rectangle { horizontal-stretch: 1; }\n"
  <> "                }\n"
  <> "                TextEdit { text: root.slint-source; read-only: true; vertical-stretch: 1; font-family: root.editor-font; font-size: root.editor-font-size; }\n"
  <> "              }\n"
  <> "            }\n"
}

fn free_canvas() -> String {
  "            if !root.slint-tab && root.layout-free: Rectangle { x: 0; y: 0; width: 100%; height: 100%; clip: true; background: root.theme-canvas;\n"
  <> "              Rectangle { x: 0; y: 0; width: root.surface-w; height: root.surface-h; background: root.theme-canvas;\n"
  <> grid_lines()
  <> "                Rectangle {\n"
  <> "                  x: root.window-x;\n"
  <> "                  y: root.window-y;\n"
  <> "                  width: root.canvas-w;\n"
  <> "                  height: root.canvas-h + 28px;\n"
  <> "                  Rectangle { x: 0; y: 0; width: parent.width; height: 28px; background: root.theme-surface; border-width: 1px; border-color: root.theme-border; border-radius: 4px;\n"
  <> "                    Text { x: 10px; y: 0; height: parent.height; text: root.form-title; color: root.theme-fg; font-weight: 600; vertical-alignment: center; }\n"
  <> "                    Text { x: parent.width - 90px; y: 0; height: parent.height; text: \"module window\"; color: root.theme-fg; font-size: 11px; vertical-alignment: center; opacity: 0.6; }\n"
  <> "                    TouchArea {\n"
  <> "                      pointer-event(event) => {\n"
  <> "                        if (event.kind == PointerEventKind.down) { key-handler.focus(); root.select(\"\"); root.win-moving = true; }\n"
  <> "                        if (event.kind == PointerEventKind.up && root.win-moving) {\n"
  <> "                          root.window-move-x(round(root.win-drag-x / 1px));\n"
  <> "                          root.window-move-y(round(root.win-drag-y / 1px));\n"
  <> "                          root.win-moving = false; root.win-drag-x = 0px; root.win-drag-y = 0px;\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                      moved => {\n"
  <> "                        if (self.pressed) { root.win-drag-x = self.mouse-x - self.pressed-x; root.win-drag-y = self.mouse-y - self.pressed-y; }\n"
  <> "                      }\n"
  <> "                    }\n"
  <> "                    "
  <> hint(
    "Drag to move the module window (outline preview); click to select it",
  )
  <> "\n"
  <> "                  }\n"
  <> "                  Rectangle { x: 0; y: 28px; width: parent.width; height: parent.height - 28px; background: root.theme-bg;\n"
  <> "                    border-width: !root.has-selection ? 2px : 1px;\n"
  <> "                    border-color: !root.has-selection ? root.theme-accent : root.drop-active && root.drop-candidate == \"\" ? #f0c040 : root.theme-border;\n"
  <> "                    TouchArea {\n"
  <> "                      pointer-event(event) => {\n"
  <> "                        if (event.kind == PointerEventKind.down && event.button == PointerEventButton.right) {\n"
  <> "                          key-handler.focus();\n"
  <> "                          root.context-menu(\"\");\n"
  <> "                        }\n"
  <> "                        if (event.kind == PointerEventKind.down && event.button == PointerEventButton.left) {\n"
  <> "                          key-handler.focus();\n"
  <> "                          if (root.shift-down || root.frame-tool) {\n"
  <> "                            root.marquee-active = true;\n"
  <> "                            root.marquee-x = self.mouse-x;\n"
  <> "                            root.marquee-y = self.mouse-y;\n"
  <> "                            root.marquee-w = 0px;\n"
  <> "                            root.marquee-h = 0px;\n"
  <> "                          } else { root.select(\"\"); }\n"
  <> "                        }\n"
  <> "                        if (event.kind == PointerEventKind.up && root.marquee-active) {\n"
  <> "                          root.marquee-active = false;\n"
  <> "                          root.rect-x(round(root.marquee-x / 1px));\n"
  <> "                          root.rect-y(round(root.marquee-y / 1px));\n"
  <> "                          root.rect-w(round(root.marquee-w / 1px));\n"
  <> "                          root.rect-h(round(root.marquee-h / 1px));\n"
  <> "                          root.frame-apply();\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                      moved => {\n"
  <> "                        if (root.marquee-active) {\n"
  <> "                          root.marquee-w = self.mouse-x - root.marquee-x;\n"
  <> "                          root.marquee-h = self.mouse-y - root.marquee-y;\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                    }\n"
  <> "                    for control in root.control-items: ControlView {\n"
  <> "                      data: control; designing: true; free-layout: !control.arranged;\n"
  <> "                      additive: root.ctrl-down; drop-candidate: root.drop-candidate;\n"
  <> "                      theme-fg: root.theme-fg; theme-accent: root.theme-accent; theme-border: root.theme-border; theme-surface: root.theme-surface;\n"
  <> "                      x: control.x; y: control.y; width: control.w; height: control.h;\n"
  <> "                      select(id) => { key-handler.focus(); root.select(id); }\n"
  <> "                      toggle-select(id) => { key-handler.focus(); root.toggle-select(id); }\n"
  <> "                      drag-start() => { root.drag-start(); }\n"
  <> "                      drag-over-x(value) => { root.drag-over-x(value); }\n"
  <> "                      drag-over-y(value) => { root.drag-over-y(value); }\n"
  <> "                      move-x(dx) => { root.move-x(dx); }\n"
  <> "                      move-y(dy) => { root.move-y(dy); }\n"
  <> "                      resize-left(dx) => { root.resize-left(dx); }\n"
  <> "                      resize-right(dx) => { root.resize-right(dx); }\n"
  <> "                      resize-top(dy) => { root.resize-top(dy); }\n"
  <> "                      resize-bottom(dy) => { root.resize-bottom(dy); }\n"
  <> "                      gesture-start() => { root.gesture-start(); }\n"
  <> "                      gesture-end() => { root.gesture-end(); }\n"
  <> "                      context-menu(id) => { root.context-menu(id); }\n"
  <> "                    }\n"
  <> "                    if (root.shift-down || root.frame-tool) && !root.marquee-active: DottedFrame {\n"
  <> "                      x: 1px; y: 1px; width: parent.width - 2px; height: parent.height - 2px; dot-color: #e5c07b;\n"
  <> "                    }\n"
  <> "                    if root.marquee-active: DottedFrame {\n"
  <> "                      x: root.marquee-w < 0px ? root.marquee-x + root.marquee-w : root.marquee-x;\n"
  <> "                      y: root.marquee-h < 0px ? root.marquee-y + root.marquee-h : root.marquee-y;\n"
  <> "                      width: root.marquee-w < 0px ? -root.marquee-w : root.marquee-w;\n"
  <> "                      height: root.marquee-h < 0px ? -root.marquee-h : root.marquee-h;\n"
  <> "                      dot-color: root.theme-accent;\n"
  <> "                    }\n"
  <> "                    if root.pending-kind != \"\": Rectangle {\n"
  <> "                      x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "                      TouchArea {\n"
  <> "                        mouse-cursor: MouseCursor.crosshair;\n"
  <> "                        pointer-event(event) => {\n"
  <> "                          if (event.kind == PointerEventKind.down) {\n"
  <> "                            root.place-active = true;\n"
  <> "                            root.place-x = self.mouse-x;\n"
  <> "                            root.place-y = self.mouse-y;\n"
  <> "                            root.place-w = 0px;\n"
  <> "                            root.place-h = 0px;\n"
  <> "                          }\n"
  <> "                          if (event.kind == PointerEventKind.up && root.place-active) {\n"
  <> "                            root.place-active = false;\n"
  <> "                            root.rect-x(round(root.place-x / 1px));\n"
  <> "                            root.rect-y(round(root.place-y / 1px));\n"
  <> "                            root.rect-w(round(root.place-w / 1px));\n"
  <> "                            root.rect-h(round(root.place-h / 1px));\n"
  <> "                            root.place-apply();\n"
  <> "                          }\n"
  <> "                        }\n"
  <> "                        moved => {\n"
  <> "                          if (self.pressed) { root.place-w = self.mouse-x - root.place-x; root.place-h = self.mouse-y - root.place-y; }\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                      if root.place-active: Rectangle {\n"
  <> "                        x: root.place-w < 0px ? root.place-x + root.place-w : root.place-x;\n"
  <> "                        y: root.place-h < 0px ? root.place-y + root.place-h : root.place-y;\n"
  <> "                        width: root.place-w < 0px ? -root.place-w : root.place-w;\n"
  <> "                        height: root.place-h < 0px ? -root.place-h : root.place-h;\n"
  <> "                        border-width: 1px; border-color: root.theme-accent; background: transparent;\n"
  <> "                      }\n"
  <> "                    }\n"
  <> "                  }\n"
  <> "                  if !root.has-selection: Rectangle {\n"
  <> "                    x: parent.width - 14px; y: parent.height - 14px; width: 14px; height: 14px;\n"
  <> "                    background: root.theme-accent; border-radius: 2px;\n"
  <> "                    TouchArea {\n"
  <> "                      pointer-event(event) => {\n"
  <> "                        if (event.kind == PointerEventKind.down) { root.gesture-start(); root.win-resizing = true; }\n"
  <> "                        if (event.kind == PointerEventKind.up && root.win-resizing) {\n"
  <> "                          root.window-resize-w(round(root.win-resize-dw / 1px));\n"
  <> "                          root.window-resize-h(round(root.win-resize-dh / 1px));\n"
  <> "                          root.gesture-end();\n"
  <> "                          root.win-resizing = false; root.win-resize-dw = 0px; root.win-resize-dh = 0px;\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                      moved => {\n"
  <> "                        if (self.pressed) { root.win-resize-dw = self.mouse-x - self.pressed-x; root.win-resize-dh = self.mouse-y - self.pressed-y; }\n"
  <> "                      }\n"
  <> "                    }\n"
  <> "                    "
  <> hint("Resize the module window (outline preview)")
  <> "\n"
  <> "                  }\n"
  <> "                }\n"
  <> "                if root.context-open: Rectangle { x: 0; y: 0; width: 100%; height: 100%; background: transparent;\n"
  <> "                  TouchArea { clicked => { root.close-context-menu(); } }\n"
  <> "                  Rectangle { x: max(0px, min(root.window-x + root.context-x, root.surface-w - 158px)); y: max(0px, min(root.window-y + 28px + root.context-y, root.surface-h - 132px)); width: 150px; height: 124px;\n"
  <> "                    background: root.theme-bg; border-width: 1px; border-color: root.theme-border; border-radius: 4px;\n"
  <> "                    VerticalLayout { padding: 4px; spacing: 1px;\n"
  <> "                      Button { text: \"Copy\"; height: 26px; enabled: root.has-selection; clicked => { root.context-copy(); } }\n"
  <> "                      Button { text: \"Cut\"; height: 26px; enabled: root.has-selection; clicked => { root.context-cut(); } }\n"
  <> "                      Button { text: \"Paste\"; height: 26px; clicked => { root.context-paste(); } }\n"
  <> "                      Button { text: \"Delete\"; height: 26px; enabled: root.has-selection; clicked => { root.context-delete(); } }\n"
  <> "                    }\n"
  <> "                  }\n"
  <> "                }\n"
  <> "                if root.win-moving || root.win-resizing: Rectangle {\n"
  <> "                  x: root.window-x + root.win-drag-x;\n"
  <> "                  y: root.window-y + root.win-drag-y;\n"
  <> "                  width: max(120px, root.canvas-w + root.win-resize-dw);\n"
  <> "                  height: max(80px, root.canvas-h + root.win-resize-dh) + 28px;\n"
  <> "                  border-width: 2px; border-color: root.theme-accent; border-radius: 4px; background: transparent;\n"
  <> "                }\n"
  <> "              }\n"
  <> "            }\n"
}

fn up_to(limit: Int) -> List(Int) {
  up_to_acc(limit, 0, [])
}

fn up_to_acc(limit: Int, i: Int, acc: List(Int)) -> List(Int) {
  case i >= limit {
    True -> list.reverse(acc)
    False -> up_to_acc(limit, i + 1, [i, ..acc])
  }
}

fn grid_lines() -> String {
  let vertical =
    up_to(60)
    |> list.map(fn(i) {
      "                Rectangle { x: "
      <> int.to_string(i * 24)
      <> "px; y: 0; width: 1px; height: 100%; background: root.theme-grid; }\n"
    })
    |> string.concat
  let horizontal =
    up_to(40)
    |> list.map(fn(i) {
      "                Rectangle { x: 0; y: "
      <> int.to_string(i * 24)
      <> "px; width: 100%; height: 1px; background: root.theme-grid; }\n"
    })
    |> string.concat
  vertical <> horizontal
}

fn column_canvas() -> String {
  "            if !root.slint-tab && root.layout-column: ScrollView { width: 100%; height: 100%;\n"
  <> "              VerticalLayout { padding: root.form-border-size; spacing: 6px;\n"
  <> "                for control in root.control-items: ControlView {\n"
  <> "                  data: control; designing: true; free-layout: false; height: control.h;\n"
  <> "                  theme-fg: root.theme-fg; theme-accent: root.theme-accent; theme-border: root.theme-border; theme-surface: root.theme-surface;\n"
  <> "                  select(id) => { key-handler.focus(); root.select(id); }\n"
  <> "                }\n"
  <> "              }\n"
  <> "            }\n"
}

fn row_canvas() -> String {
  "            if !root.slint-tab && root.layout-row: ScrollView { width: 100%; height: 100%;\n"
  <> "              HorizontalLayout { padding: root.form-border-size; spacing: 6px; height: 100%;\n"
  <> "                for control in root.control-items: ControlView {\n"
  <> "                  data: control; designing: true; free-layout: false; width: control.w; height: 100%;\n"
  <> "                  theme-fg: root.theme-fg; theme-accent: root.theme-accent; theme-border: root.theme-border; theme-surface: root.theme-surface;\n"
  <> "                  select(id) => { key-handler.focus(); root.select(id); }\n"
  <> "                }\n"
  <> "              }\n"
  <> "            }\n"
}

fn code_view() -> String {
  "          if root.code-view && !root.code-editing: Rectangle { width: 100%; height: 100%; background: root.code-bg;\n"
  <> "            VerticalLayout { spacing: 0px;\n"
  <> "              HorizontalLayout { height: 32px; padding-left: 10px; padding-right: 8px; spacing: 6px;\n"
  <> "                Text { text: \"Handler code\"; color: root.code-name; font-weight: 600; vertical-alignment: center; }\n"
  <> "                Text { text: root.code-handler; color: root.code-string; vertical-alignment: center; }\n"
  <> "                Rectangle { horizontal-stretch: 1; }\n"
  <> "                Button { text: \"View\"; clicked => { root.editor-view(); } "
  <> hint("View the highlighted handler code")
  <> " }\n"
  <> "                Button { text: \"✎ Edit\"; enabled: root.has-handler; clicked => { root.editor-edit(); } "
  <> hint("Edit the selected handler")
  <> " }\n"
  <> "              }\n"
  <> "              ScrollView { vertical-stretch: 1; content-y: root.code-scroll;\n"
  <> "                Rectangle { width: 100%; height: root.code-height;\n"
  <> "                  Rectangle { x: 0; y: root.hl-top; width: 100%; height: root.hl-height; background: root.theme-tint; }\n"
  <> "                  Rectangle { x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "                    VerticalLayout { spacing: 0px; padding-top: 4px; padding-bottom: 4px;\n"
  <> "                      for line in root.code-lines: HorizontalLayout { height: 18px; alignment: start; padding-left: 10px; spacing: 0px;\n"
  <> "                        for token in line.tokens: Text {\n"
  <> "                          text: token.text;\n"
  <> "                          font-family: root.editor-font; font-size: root.editor-font-size;\n"
  <> "                          color: token.kind == \"comment\" ? root.code-comment : token.kind == \"keyword\" ? root.code-keyword : token.kind == \"string\" ? root.code-string : token.kind == \"number\" ? root.code-number : token.kind == \"type\" ? root.code-type : token.kind == \"punct\" ? root.code-punct : root.code-name;\n"
  <> "                          wrap: TextWrap.no-wrap;\n"
  <> "                        }\n"
  <> "                      }\n"
  <> "                    }\n"
  <> "                  }\n"
  <> "                }\n"
  <> "              }\n"
  <> "            }\n"
  <> "          }\n"
}

fn editor_view() -> String {
  "          if root.code-editing: Rectangle { width: 100%; height: 100%; background: root.code-bg;\n"
  <> "            VerticalLayout { spacing: 0px;\n"
  <> "              HorizontalLayout { height: 32px; padding-left: 10px; padding-right: 8px; spacing: 6px;\n"
  <> "                Text { text: \"Handler code\"; color: root.code-name; font-weight: 600; vertical-alignment: center; }\n"
  <> "                Text { text: root.code-handler; color: root.code-string; vertical-alignment: center; }\n"
  <> "                Rectangle { horizontal-stretch: 1; }\n"
  <> "              }\n"
  <> "              VerticalLayout { vertical-stretch: 1; padding: 8px; spacing: 4px;\n"
  <> "                code-input := TextEdit { text <=> root.code-text; vertical-stretch: 1; font-family: root.editor-font; font-size: root.editor-font-size; }\n"
  <> "                HorizontalLayout { spacing: 6px;\n"
  <> "                  Button { text: \"✓ Apply\"; primary: true; clicked => { root.code-apply(code-input.text); } "
  <> hint("Apply the handler code")
  <> " }\n"
  <> "                  Button { text: \"✕ Cancel\"; clicked => { root.editor-view(); } "
  <> hint("Cancel editing")
  <> " }\n"
  <> "                  Rectangle { horizontal-stretch: 1; }\n"
  <> "                }\n"
  <> "              }\n"
  <> "            }\n"
  <> "          }\n"
}

fn right_pane() -> String {
  "      VerticalLayout { width: 320px; spacing: 6px; padding: 8px;\n"
  <> "        Text { text: root.canvas-label; color: root.theme-fg; }\n"
  <> "        Rectangle { height: 1px; background: root.theme-border; }\n"
  <> "        Text { text: \"Inspector\"; font-weight: 600; color: root.theme-fg; }\n"
  <> "        HorizontalLayout { spacing: 4px;\n"
  <> "          Button { text: \"⚙ Properties\"; primary: !root.events-tab; height: 32px; clicked => { root.tab-properties(); } "
  <> hint("Component properties")
  <> " }\n"
  <> "          Button { text: \"⚡ Events\"; primary: root.events-tab; height: 32px; clicked => { root.tab-events(); } "
  <> hint("Component events")
  <> " }\n"
  <> "        }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 6px;\n"
  <> "          Text { text: root.insp-selection; font-weight: 600; color: root.theme-fg; horizontal-stretch: 1; vertical-alignment: center; }\n"
  <> "          if root.has-selection: Rectangle { width: 38px; height: 28px; border-width: 1px; border-color: root.theme-border; border-radius: 4px; background: trash-hover.has-hover ? root.theme-tint : transparent;\n"
  <> "            trash-hover := TouchArea { clicked => { root.delete-selected(); } }\n"
  <> "            Path { x: (parent.width - 14px) / 2; y: (parent.height - 16px) / 2; width: 14px; height: 16px;\n"
  <> "              stroke: root.theme-fg; stroke-width: 1.2px; fill: transparent;\n"
  <> "              commands: \"M 1 4 L 13 4 M 5 4 L 5 1 L 9 1 L 9 4 M 2.5 4 L 3.5 15 L 10.5 15 L 11.5 4 M 5.5 7 L 5.5 12 M 8.5 7 L 8.5 12\";\n"
  <> "            }\n"
  <> "            "
  <> hint("Delete the selected component(s) (Del)")
  <> "\n"
  <> "          }\n"
  <> "        }\n"
  <> "        if root.has-selection && !root.events-tab: VerticalLayout { spacing: 6px;\n"
  <> field("Name", "insp-name", "field-name")
  <> field("Text", "insp-text", "field-text")
  <> "          if root.selected-kind == \"picture\": Button { text: \"▧ Choose picture…\"; clicked => { root.browse-picture(); } "
  <> hint("Choose an image file for this picture")
  <> " }\n"
  <> field("X", "insp-x", "field-x")
  <> field("Y", "insp-y", "field-y")
  <> field("W", "insp-w", "field-w")
  <> field("H", "insp-h", "field-h")
  <> "          if root.layout-free: HorizontalLayout { height: 30px; spacing: 6px;\n"
  <> "            Text { text: \"Align\"; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            ComboBox { model: [\"None (free)\", \"Top\", \"Bottom\", \"Left\", \"Right\", \"Client\", \"Fill\"]; current-index: root.align-index; selected => { root.set-align(self.current-value); } }\n"
  <> "          }\n"
  <> "          if root.container-layout-index >= 0: HorizontalLayout { height: 30px; spacing: 6px;\n"
  <> "            Text { text: \"Layout\"; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            ComboBox { model: [\"Free\", \"Column\", \"Row\"]; current-index: root.container-layout-index; selected => { root.set-container-layout(self.current-value); } }\n"
  <> "          }\n"
  <> "          if root.container-layout-index >= 0: HorizontalLayout { height: 30px; spacing: 6px;\n"
  <> "            Text { text: \"Border\"; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            LineEdit { text <=> root.insp-border; horizontal-stretch: 1; accepted(text) => { root.field-border(text); } }\n"
  <> "          }\n"
  <> check_row("Enabled", "insp-enabled", "toggle-enabled")
  <> check_row("Visible", "insp-visible", "toggle-visible")
  <> "          Rectangle { vertical-stretch: 1; }\n"
  <> "        }\n"
  <> "        if root.project-selected: VerticalLayout { spacing: 6px;\n"
  <> "          HorizontalLayout { height: 54px; spacing: 8px;\n"
  <> "            for project in root.project-items: Rectangle { width: project.active ? 48px : 0px; height: project.active ? 48px : 0px; clip: true;\n"
  <> "              border-width: project.active ? 1px : 0px; border-color: root.theme-border; border-radius: 4px; background: root.theme-surface;\n"
  <> "              if project.active && project.has-icon: Image { x: 4px; y: 4px; width: parent.width - 8px; height: parent.height - 8px; source: project.icon; image-fit: contain; }\n"
  <> "              if project.active && !project.has-icon: Text { x: 0; y: 0; width: 100%; height: 100%; text: \"▤\"; font-size: 22px; horizontal-alignment: center; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            }\n"
  <> "            VerticalLayout { spacing: 4px;\n"
  <> "              Button { text: \"Choose icon…\"; height: 26px; clicked => { root.browse-project-icon(); } "
  <> hint("Choose an image for this project")
  <> " }\n"
  <> "              Button { text: \"Clear icon\"; height: 26px; clicked => { root.clear-project-icon(); } "
  <> hint("Remove the project icon")
  <> " }\n"
  <> "            }\n"
  <> "          }\n"
  <> field("Title", "project-title", "field-project-title")
  <> "          Text { text: \"Path\"; color: root.theme-fg; }\n"
  <> "          Text { text: root.project-path; color: root.theme-fg; overflow: elide; }\n"
  <> "          Text { text: root.project-module-count; color: root.theme-fg; }\n"
  <> "          Text { text: \"Project properties are edited like component properties.\"; color: root.theme-fg; height: 32px; wrap: word-wrap; }\n"
  <> "          Rectangle { vertical-stretch: 1; }\n"
  <> "        }\n"
  <> "        if !root.has-selection && !root.project-selected: VerticalLayout { spacing: 6px;\n"
  <> field("Title", "form-title", "field-title")
  <> field("Width", "form-width", "field-width")
  <> field("Height", "form-height", "field-height")
  <> "          HorizontalLayout { height: 32px; spacing: 6px;\n"
  <> "            Text { text: \"Layout\"; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            ComboBox { model: [\"Free\", \"Column\", \"Row\"]; current-index: root.layout-index; selected => { root.set-layout(self.current-value); } }\n"
  <> "          }\n"
  <> field("Border", "form-border", "field-border")
  <> "        }\n"
  <> "        if root.has-selection && root.events-tab: VerticalLayout { spacing: 6px;\n"
  <> "          if root.has-events: HorizontalLayout { spacing: 6px; height: 32px;\n"
  <> "            Text { text: root.event-label; width: 116px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            Button { text: root.event-handler; horizontal-stretch: 1; clicked => { root.edit-event(\"clicked\"); } "
  <> hint("Open this event handler")
  <> " }\n"
  <> "          }\n"
  <> "          if !root.has-events: Text { text: \"No events\"; color: root.theme-fg; }\n"
  <> "          if root.has-events: Text { text: \"Click the event to open its handler.\"; color: root.theme-fg; }\n"
  <> "        }\n"
  <> "      }\n"
}

fn field(label: String, property: String, callback: String) -> String {
  "          HorizontalLayout { height: 30px; spacing: 6px;\n"
  <> "            Text { text: "
  <> quote(label)
  <> "; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            LineEdit { text <=> root."
  <> property
  <> "; horizontal-stretch: 1; accepted(text) => { root."
  <> callback
  <> "(text); } }\n"
  <> "          }\n"
}

fn check_row(label: String, property: String, callback: String) -> String {
  "          HorizontalLayout { height: 28px; spacing: 6px;\n"
  <> "            Text { text: "
  <> quote(label)
  <> "; width: 64px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "            CheckBox { checked <=> root."
  <> property
  <> "; toggled => { root."
  <> callback
  <> "(self.checked); } }\n"
  <> "          }\n"
}

fn status_bar() -> String {
  "    HorizontalLayout { height: 26px; padding-left: 10px; padding-right: 10px; spacing: 8px;\n"
  <> "      Text { text: root.status; color: root.theme-fg; vertical-alignment: center; }\n"
  <> "      Rectangle { horizontal-stretch: 1; }\n"
  <> "      Text { text: root.path-text; color: root.theme-fg; vertical-alignment: center; }\n"
  <> "    }\n"
}

fn hint(text: String) -> String {
  " if root.show-hints: Tooltip { text: @markdown(" <> quote(text) <> "); }"
}

fn settings_overlay() -> String {
  "  if root.settings-open: Rectangle {\n"
  <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "    TouchArea { clicked => { root.close-settings(); } }\n"
  <> "    Rectangle { x: (root.width - self.width) / 2; y: 120px; width: 520px; height: 330px;\n"
  <> "      background: root.theme-bg; border-width: 1px; border-color: root.theme-border; border-radius: 6px;\n"
  <> "      VerticalLayout { padding: 18px; spacing: 12px;\n"
  <> "        Text { text: \"Editor settings\"; font-size: 18px; font-weight: 600; color: root.theme-fg; }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 8px;\n"
  <> "          Text { text: \"Font\"; width: 110px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "          ComboBox { model: "
  <> string_list(fonts)
  <> "; current-index: root.font-index; selected => { root.font-selected(self.current-value); } }\n"
  <> "        }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 8px;\n"
  <> "          Text { text: \"Font size\"; width: 110px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "          ComboBox { model: "
  <> string_list(sizes)
  <> "; current-index: root.size-index; selected => { root.font-size-selected(self.current-value); } }\n"
  <> "        }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 8px;\n"
  <> "          Text { text: \"Color scheme\"; width: 110px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "          ComboBox { model: [\"Dark\", \"Light\", \"Solarized\"]; current-index: root.scheme-index; selected => { root.scheme-selected(self.current-value); } }\n"
  <> "        }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 8px;\n"
  <> "          Text { text: \"UI\"; width: 110px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "          CheckBox { text: \"Show UI hints\"; checked: root.show-hints; toggled => { root.toggle-hints(self.checked); }"
  <> hint("Enable tooltips on buttons and tabs")
  <> " }\n"
  <> "        }\n"
  <> "        Rectangle { vertical-stretch: 1; }\n"
  <> "        HorizontalLayout { spacing: 8px;\n"
  <> "          Button { text: \"Close\"; primary: true; height: 32px; clicked => { root.close-settings(); }"
  <> hint("Close the settings dialog")
  <> " }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
}

fn project_dialog_overlay() -> String {
  "  if root.project-dialog-open: Rectangle {\n"
  <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "    TouchArea { clicked => { root.close-project-dialog(); } }\n"
  <> "    Rectangle { x: (root.width - self.width) / 2; y: 160px; width: 460px; height: 240px;\n"
  <> "      background: root.theme-bg; border-width: 1px; border-color: root.theme-border; border-radius: 6px;\n"
  <> "      VerticalLayout { padding: 18px; spacing: 12px;\n"
  <> "        Text { text: \"Projects\"; font-size: 18px; font-weight: 600; color: root.theme-fg; }\n"
  <> "        Text { text: \"Create a new project or open an existing project into this workspace.\"; color: root.theme-fg; height: 32px; wrap: word-wrap; }\n"
  <> "        Button { text: \"Create new project\"; primary: true; height: 32px; clicked => { root.dialog-new-project(); }"
  <> hint("Create a new project in the workspace")
  <> " }\n"
  <> "        Button { text: \"Open existing project…\"; height: 32px; clicked => { root.dialog-open-project(); }"
  <> hint("Open a project file into the workspace")
  <> " }\n"
  <> "        Rectangle { vertical-stretch: 1; }\n"
  <> "        HorizontalLayout {\n"
  <> "          Button { text: \"Cancel\"; clicked => { root.close-project-dialog(); }"
  <> hint("Cancel")
  <> " }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
}

fn agent_overlay() -> String {
  "  if root.agent-open: Rectangle {\n"
  <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "    TouchArea { clicked => { root.close-agent(); } }\n"
  <> "    Rectangle { x: (root.width - self.width) / 2; y: 140px; width: 560px; height: 300px;\n"
  <> "      background: root.theme-bg; border-width: 1px; border-color: root.theme-border; border-radius: 6px;\n"
  <> "      VerticalLayout { padding: 18px; spacing: 12px;\n"
  <> "        Text { text: \"Agent settings\"; font-size: 18px; font-weight: 600; color: root.theme-fg; }\n"
  <> "        CheckBox { text: \"Enable MCP server\"; checked: root.mcp-enabled; toggled => { root.toggle-mcp(self.checked); }"
  <> hint("Expose Campy tools over local MCP")
  <> " }\n"
  <> "        HorizontalLayout { height: 32px; spacing: 8px;\n"
  <> "          Text { text: \"Port\"; width: 110px; vertical-alignment: center; color: root.theme-fg; }\n"
  <> "          port-input := LineEdit { text <=> root.mcp-port-text; horizontal-stretch: 1; accepted(text) => { root.mcp-port(text); } }\n"
  <> "        }\n"
  <> "        Text { text: root.mcp-status; color: root.theme-fg; }\n"
  <> "        Text { text: \"Endpoint: http://127.0.0.1:\" + root.mcp-port-text + \"/mcp\"; color: root.theme-fg; }\n"
  <> "        Text { text: \"Disabled by default. The server listens on localhost only.\"; color: root.theme-fg; }\n"
  <> "        Rectangle { vertical-stretch: 1; }\n"
  <> "        HorizontalLayout { spacing: 8px;\n"
  <> "          Button { text: \"Close\"; primary: true; height: 32px; clicked => { root.close-agent(); }"
  <> hint("Close the agent settings")
  <> " }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
}

fn popup_overlay() -> String {
  "  if root.popup-open: Rectangle {\n"
  <> "    x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "    TouchArea { clicked => { root.file-cancel(); } }\n"
  <> "    Rectangle { x: (root.width - self.width) / 2; y: 160px; width: 500px; height: 190px;\n"
  <> "      background: root.theme-bg; border-width: 1px; border-color: root.theme-border; border-radius: 6px;\n"
  <> "      VerticalLayout { padding: 16px; spacing: 10px;\n"
  <> "        Text { text: root.popup-title; font-size: 18px; font-weight: 600; color: root.theme-fg; }\n"
  <> "        Text { text: \"Relative to the project root, or an absolute path.\"; color: root.theme-fg; }\n"
  <> "        path-field := LineEdit { text <=> root.popup-path; }\n"
  <> "        HorizontalLayout { spacing: 8px;\n"
  <> "          Button { text: root.popup-action; primary: true; clicked => { root.popup-accept(path-field.text); } "
  <> hint("Confirm")
  <> " }\n"
  <> "          Button { text: \"Cancel\"; clicked => { root.file-cancel(); } "
  <> hint("Cancel")
  <> " }\n"
  <> "          Rectangle { horizontal-stretch: 1; }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
  <> "  }\n"
}

// ---------------------------------------------------------------------------
// Values used by both updates() and the baked defaults
// ---------------------------------------------------------------------------

fn dot_range() -> String {
  "[" <> string.join(list.map(int_range(0, 23), int.to_string), ", ") <> "]"
}

fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

fn pending_kind_key(model: State) -> String {
  case model.pending_kind {
    Some(kind) -> campy_form.kind_key(kind)
    None -> ""
  }
}

fn module_count_text(model: State) -> String {
  let count = list.length(model.project.modules)
  case count {
    1 -> "1 module"
    _ -> int.to_string(count) <> " modules"
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

fn is_editing_code(model: State) -> Bool {
  case model.editor {
    Edit -> True
    View -> False
  }
}

fn is_some(option: Option(a)) -> Bool {
  case option {
    Some(_) -> True
    None -> False
  }
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

fn canvas_label(form: Option(Form)) -> String {
  case form {
    Some(value) ->
      "Canvas "
      <> int.to_string(value.width)
      <> " × "
      <> int.to_string(value.height)
    None -> ""
  }
}

fn code_handler_label(model: State) -> String {
  case model.active_handler {
    Some(handler) -> handler
    None -> active_name(model)
  }
}

fn code_text(model: State) -> String {
  case model.editing {
    Some(Editing(text, _)) -> text
    None -> ""
  }
}

fn highlight_scroll(model: State) -> Int {
  case model.highlight {
    Some(#(start, _)) -> start * 18
    None -> 0
  }
}

fn highlight_top(model: State) -> Int {
  case model.highlight {
    Some(#(start, _)) -> 4 + start * 18
    None -> 0
  }
}

fn highlight_height(model: State) -> Int {
  case model.highlight {
    Some(#(start, end)) -> end * 18 - start * 18 + 18
    None -> 0
  }
}

fn code_height(model: State) -> Int {
  case active_module(model) {
    Some(module) -> list.length(string.split(module.source, "\n")) * 18 + 8
    None -> 0
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

fn selected_border(model: State) -> String {
  case selected_control(model), active_form(model) {
    Some(control), Some(form) ->
      case campy_form.accepts_children(control.kind) {
        True -> int.to_string(campy_form.border_of(form, control.id))
        False -> ""
      }
    _, _ -> ""
  }
}

fn form_border_size(model: State) -> Int {
  case active_form(model) {
    Some(form) -> campy_form.border_of(form, "")
    None -> 0
  }
}

fn form_border(model: State) -> String {
  case active_form(model) {
    Some(form) -> int.to_string(campy_form.border_of(form, ""))
    None -> "0"
  }
}

fn container_layout_index(model: State) -> Int {
  case selected_control(model), active_form(model) {
    Some(control), Some(form) ->
      case campy_form.accepts_children(control.kind) {
        True ->
          case campy_form.layout_of(form, control.id) {
            campy_form.Free -> 0
            campy_form.Column -> 1
            campy_form.Row -> 2
          }
        False -> -1
      }
    _, _ -> -1
  }
}

fn layout_index(form: Option(Form)) -> Int {
  case form {
    Some(value) ->
      case value.layout {
        campy_form.Free -> 0
        campy_form.Column -> 1
        campy_form.Row -> 2
      }
    None -> 0
  }
}

fn align_index(align: campy_form.Align) -> Int {
  index_of(
    ["none", "top", "bottom", "left", "right", "client", "fill"],
    campy_form.align_key(align),
  )
}

fn scheme_index(scheme: Scheme) -> Int {
  case scheme {
    Dark -> 0
    Light -> 1
    Solarized -> 2
  }
}

fn string_list(items: List(String)) -> String {
  "[" <> string.join(list.map(items, quote), ", ") <> "]"
}

fn bool(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
