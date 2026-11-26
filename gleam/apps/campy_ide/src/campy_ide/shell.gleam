//// The IDE shell, protocol v2: one `ControlDesc` document built from a
//// `ShellView` (the IDE's display state, produced by `campy_ide/ide_ui`).
////
//// `desc(view)` is the whole window: the LoadUi document (`ide_ui.load_commands`)
//// and, through the generic tree diff in `ide_ui`, the source of every granular
//// op. The document is loaded once; ordinary edits are `SetText`/`SetBool`/
//// `SetInt`/`SetModel`/`SetGeometry`/`SetCode`/`AppendConsole`/`SetMarks` ops.
////
//// # Ids
////
//// Every control id is `campy_form.wire_id(<name>)` (the same 31-bit hash the
//// designed forms use), never a hand-rolled table. `campy_form.window_id` (0)
//// is the window root. Name ↔ id glossary (derive with `campy_form.wire_id`):
////
//// | name | kind | role |
//// | --- | --- | --- |
//// | `ide-root` (id 0) | panel | window root (fixed 1280×860 shell) |
//// | `menu-bar` | panel (row) | File/Edit/Settings menus, palette, Run/Stop |
//// | `menu-file`, `menu-edit`, `menu-settings` | menu | popup menus; `model` = item labels; emits `selected` with the label |
//// | `palette` | panel (row) | CCL palette tiles |
//// | `tile:<kind>` | button | one per `campy_ccl.all()` entry; emits `clicked` |
//// | `run`, `stop` | button | Run/Stop (`enabled` follows the preview) |
//// | `menu-rule` | panel | 1px rule under the menu bar |
//// | `nav` | panel | navigator column |
//// | `nav-projects-title`, `nav-modules-title` | label | section titles |
//// | `project-add`, `project-delete` | button | project dialog / remove project |
//// | `projects-nav` | list | project rows (`SetModel` of `{text,id,active}`); emits `selected` with the title |
//// | `nav-rule` | panel | 1px rule between the two navigator lists |
//// | `module-add` | button | new module |
//// | `modules-nav` | list | module rows (`SetModel` of `{text,id,active}`); emits `selected` with the name |
//// | `tab-strip` | panel | the open module tabs; one `tab:<module id>` button per tab, emitting `clicked` |
//// | `tab-close` | button | close the active tab |
//// | `canvas` | surface | designer canvas; `pointer:canvas:down/move/up/wheel` |
//// | `canvas-title` | label | form title bar (`SetText`) |
//// | `canvas-form` | panel | the form root (from `live_preview.to_controls`, re-keyed); its children are the designed controls at their wire ids |
//// | `selection-rect` | panel | selection outline (`SetGeometry`, `SetBool visible`) |
//// | `marquee-rect` | panel | marquee outline (`SetGeometry`, `SetBool visible`) |
//// | `view-toggle` | button | form/code switch (glyph flips with `SetText`) |
//// | `canvas-rule` | panel | 1px rule above the Form/Raw tabs |
//// | `code-title`, `code-handler` | label | handler header |
//// | `code-view` | code_editor | handler source (`SetCode`, `editor:<id>:changed`) |
//// | `completions` | list | completion popup (`SetModel`, positioned by `SetGeometry`) |
//// | `console-pane` | panel | console pane |
//// | `console-title`, `console-state` | label | title + running/stopped (`SetText`) |
//// | `console-clear` | button | clear |
//// | `console` | console | `AppendConsole` feed; input → `console:console:input` |
//// | `right-pane` | panel | inspector column |
//// | `insp-tab-properties`, `insp-tab-events` | button | inspector tabs |
//// | `insp-rule` | panel | 1px rule |
//// | `insp-selection` | label | selection label (`SetText`) |
//// | `insp-delete` | button | delete selection (visible with a selection) |
//// | `project-panel` | panel | project properties (visible when the project is selected) |
//// | `project-icon` | picture | project icon |
//// | `project-icon-glyph` | label | icon placeholder |
//// | `project-icon-choose`, `project-icon-clear` | button | icon actions |
//// | `project-title-label`, `project-path-label` | label | field labels |
//// | `project-title` | edit | project title (`edited`) |
//// | `project-path` | label | project path (`SetText`) |
//// | `inspector` | panel | property rows (visible on the Properties tab) |
//// | `insp:<key>:label` | label | row label |
//// | `insp:<key>` | edit/checkbox/combo/button | one row per property key (see below) |
//// | `inspector-events` | panel | event rows (visible on the Events tab) |
//// | `insp:<event>` | button | one row per event key; emits `clicked` |
//// | `status-bar` | panel | status line |
//// | `status`, `status-path` | label | status text / project path (`SetText`) |
//// | `settings-panel` | panel (hidden) | Editor settings dialog |
//// | `settings-title`, `settings-font-label`, `settings-size-label`, `settings-scheme-label` | label | dialog text |
//// | `settings-font`, `settings-size`, `settings-scheme` | combo | settings choices (`selected`) |
//// | `settings-hints` | checkbox | UI hints (`toggled`) |
//// | `settings-close` | button | close |
//// | `agent-panel` | panel (hidden) | Agent settings dialog |
//// | `agent-title`, `agent-port-label`, `agent-status`, `agent-endpoint`, `agent-note` | label | dialog text |
//// | `agent-mcp` | checkbox | enable MCP (`toggled`) |
//// | `agent-port` | edit | port (`edited`) |
//// | `agent-close` | button | close |
//// | `project-dialog` | panel (hidden) | project dialog |
//// | `project-dialog-title`, `project-dialog-body` | label | dialog text |
//// | `project-new`, `project-open`, `project-dialog-cancel` | button | actions |
//// | `browser-panel` | panel (hidden) | in-app file browser |
//// | `browser-title`, `browser-dir` | label | title / directory (`SetText`) |
//// | `browser-home`, `browser-new-dir`, `browser-up` | button | navigation |
//// | `browser-entries` | list | entries (`SetModel`); emits `selected` with the entry name |
//// | `browser-name-label` | label | field label |
//// | `browser-name` | edit | entry name (`edited`) |
//// | `browser-accept`, `browser-cancel` | button | confirm / cancel |
//// | `context-menu` | panel (hidden) | canvas context menu |
//// | `ctx-cut`, `ctx-copy`, `ctx-paste`, `ctx-delete`, `ctx-align` | button | actions |
//// | `align-menu` | panel (hidden) | align submenu |
//// | `align-left`, `align-right`, `align-center`, `align-top`, `align-bottom`, `align-middle` | button | align actions |
//// | `nav-context` | panel (hidden) | navigator context menu |
//// | `nav-ctx-remove`, `nav-ctx-open`, `nav-ctx-delete`, `nav-ctx-close-tab` | button | actions |
////
//// # Events
////
//// Buttons emit `control:<id>:clicked`; menus/lists/combos emit
//// `control:<id>:selected` with the selected *text*; inspector edit rows emit
//// `edited` with the typed value; checkbox rows emit `toggled` with
//// `"true"`/`"false"`; the console emits `console:<id>:input`; the code editor
//// emits `editor:<id>:changed`; the canvas emits `pointer:<id>:<phase>`.
//// Payloads are values only: the loop derives the action from the section id
//// (and, for menus, from the selected label — the labels below are the old
//// shell's item titles verbatim, shortcuts included). Menu items are *not*
//// individual controls: the `menu` kind carries them as its `model` (a
//// delimiter-free list of labels), so the selected label is the payload.
//// Separator rows are the em-dash label `—`.
////
//// # Inspector rows
////
//// Rows are a *static pool* (one control per key, ids `insp:<key>`), so a
//// selection change never reloads the document: the diff shows/hides rows and
//// moves them with `SetGeometry`. `prop_keys()`/`event_keys()` enumerate the
//// pool (fixed IDE keys + every `campy_ccl` schema key). Row kind per key:
//// `edit` (Text/Number keys, `edited`), `checkbox` (Bool keys, `toggled`),
//// `combo` (align/layout/color, `selected`), `button` (picture open + event
//// rows, `clicked`). The universal CCL `text` row routes to the same editor as
//// the text field (Z1.1 note): it is `insp:text`, an `edit`.
////
//// # Mapping notes (old shell → v2)
////
//// - Hover tooltips and palette status-line hints have no protocol event
////   (there is no hover kind), so hint texts ride as static `hint` props and
////   the status line still exists for `SetText`. The 20 keyboard bindings
////   (Ctrl+Z/Y, Ctrl+C/X/V, Delete, Ctrl+N/Shift+N/O/S/Shift+S/Q, F5/F6/F7,
////   Shift+F5, Ctrl+Tab, Ctrl+Space, Escape) cross as renderer `key` events
////   (`ctrl+s`, `f6`, `delete`, …) and are routed by `campy_ide`'s loop.
//// - The old tab strip had a per-tab × control. Tabs are now one button per
////   open module (`tab:<module id>`, so a click names its module) plus
////   `tab-close` (close the active tab); the navigator context menu keeps its
////   "Close tab" item as well.
//// - Adding/removing a designed control changes the canvas subtree, which no
////   granular op can express: the tree diff reports a structural change and
////   `ide_ui` answers with a fresh LoadUi (the same path F6 uses). Ordinary
////   edits stay granular.
//// - The old "Raw" tab rendered generated Slint source; protocol v2 has no
////   source generation, so `raw-view` shows the active module's source
////   read-only.
//// - The old console was a log list plus a Send field; the v2 `console` kind is
////   a terminal that feeds input itself (`console:console:input`), so the
////   separate input row is gone.
//// - Every control carries a static `class` prop (one, space-joined: the view
////   diff looks props up by key) naming its styling role. The renderer applies
////   it beside the `campy-<kind>` class it derives.
//// - The shell's absolute layout is the old fixed chrome at 1280×860; panels do
////   not stretch when the window is enlarged (no responsive geometry op).
//// - The designer chrome is canvas content, not controls: `selection-rect` is
////   the union box of the selection, `marquee-rect` follows a live
////   marquee/placement drag (`SetGeometry` + `visible` from the view), and the
////   eight resize handles are hit-tested by the BEAM gesture layer (they were
////   per-control Slint children, which a surface cannot host).
////   The completion popup is a `list` whose position `ide_ui`/Z2.3 sets with
////   `SetGeometry` (the caret lives in the editor, not in this view).
//// - Right-click on a navigator row (`nav-context`) needs a pointer event on a
////   `list` row; §1.4 only defines `selected` for lists, so the menu can render
////   but has no wire trigger yet (protocol gap, same family as hover/keys).
//// - The canvas drop highlight (`drop-candidate`) and the pending palette tile
////   were class/background switches; protocol v2 has no class op, so they are
////   not drawn (the marquee rectangle is the placement preview meanwhile).
////
//// # Renderer gaps found by Z2.3 (in the renderer, not this document)
////
//// - `list` rows emit `selected` with the row text (gap closed): the loop
////   routes `projects-nav`, `modules-nav`, `completions` and
////   `browser-entries` from it.
//// - `menu` renders as a plain button (no popup, emits `clicked`), so the
////   File/Edit/Settings items are not reachable until the renderer builds the
////   zgui `Menu`; the loop routes `selected` labels by the old item titles.
//// - `pointer:<id>:*` carries no button or modifiers, so right-click (the
////   canvas context menu) and Ctrl-click (additive selection) have no wire
////   form; `campy_ide` maps Shift+F10 to the context menu and the marquee to
////   multi-select instead.
//// - A second `LoadUi` on a live session is accepted (`ui-loaded`) but the
////   window does not rebuild from the new document, so `Reload` (structural
////   edits, theme, module switch) does not display until the renderer reads
////   its document signal tracked.

import campy_bridge.{
  type ControlDesc, type WireValue, ControlDesc, WireBool, WireImage, WireInt,
  WireList, WireStruct, WireText,
}
import campy_ccl
import campy_form
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The size the shell opens at (LoadUi width/height when the window has not
/// reported its own yet). The layout below stretches to any size: the window
/// reports a resize and the document is re-emitted against it.
pub const window_width = 1280

pub const window_height = 860

/// The module window's title-bar height inside the canvas.
pub const form_title_height = 28

/// One selection grip: the square drawn at a corner or edge midpoint of the
/// selection, and the size the BEAM hit-tests (`state.resize_grip`).
pub const grip_size = 6

/// How many selected controls draw their own outline (the marquee can pick
/// more than this; the union box still covers them).
pub const member_pool = 24

/// Every pane rectangle for one window size, in window CSS pixels.
///
/// The shell is one hand-placed frame: the navigator and the inspector keep
/// their widths, the menu bar and status line their heights, and the centre
/// column, the canvas and the console take whatever is left. `campy_ide`'s
/// pointer routing subtracts `canvas_x`/`canvas_y` to reach form-local
/// coordinates, so the canvas lives here rather than in a constant.
pub type Layout {
  Layout(
    width: Int,
    height: Int,
    /// Menu bar height, and the body's top edge (the 1px rule sits between).
    menu_h: Int,
    body_y: Int,
    nav_w: Int,
    nav_h: Int,
    centre_x: Int,
    centre_w: Int,
    right_x: Int,
    right_w: Int,
    right_h: Int,
    /// The inspector/project panel's height (below the inspector's tabs).
    pane_h: Int,
    status_y: Int,
    status_h: Int,
    tabstrip_y: Int,
    tabstrip_h: Int,
    canvas_x: Int,
    canvas_y: Int,
    canvas_w: Int,
    canvas_h: Int,
    /// The 1px rule above the form/raw tabs, the tab row, the console.
    rule_y: Int,
    tabs_y: Int,
    console_y: Int,
    console_h: Int,
    console_w: Int,
  )
}

/// The panes for a window of `width` x `height`.
pub fn layout(width: Int, height: Int) -> Layout {
  let menu_h = 46
  let body_y = menu_h + 1
  let nav_w = 190
  let right_w = 320
  let status_h = 26
  let tabstrip_h = 32
  let console_h = 171
  let tabs_h = 30
  let centre_x = nav_w + 1
  let right_x = int.max(width - right_w, centre_x)
  // A window dragged smaller than the chrome cannot have a negative pane: the
  // centre column and the canvas keep a usable minimum and the rest clips.
  let centre_w = int.max(right_x - centre_x - 1, 160)
  let status_y = height - status_h
  let console_y = int.max(status_y - console_h, body_y + 120)
  let tabs_y = console_y - tabs_h
  let rule_y = int.max(tabs_y - 4, body_y + 120)
  let canvas_y = body_y + tabstrip_h
  Layout(
    width: width,
    height: height,
    menu_h: menu_h,
    body_y: body_y,
    nav_w: nav_w,
    nav_h: int.max(height - body_y - status_h, 200),
    centre_x: centre_x,
    centre_w: centre_w,
    right_x: right_x,
    right_w: right_w,
    right_h: int.max(height - body_y - status_h, 200),
    pane_h: int.max(height - body_y - status_h - 88, 112),
    status_y: status_y,
    status_h: status_h,
    tabstrip_y: body_y,
    tabstrip_h: tabstrip_h,
    canvas_x: centre_x,
    canvas_y: canvas_y,
    canvas_w: centre_w,
    canvas_h: int.max(rule_y - canvas_y, 120),
    rule_y: rule_y,
    tabs_y: tabs_y,
    console_y: console_y,
    console_h: console_h,
    console_w: centre_w,
  )
}

/// Font and size choices offered by the settings dialog (public: `ide_ui` maps
/// the current font/size onto the same lists, so value and model agree).
pub const fonts = [
  "monospace", "DejaVu Sans Mono", "Liberation Mono", "Courier New",
  "Noto Sans Mono",
]

pub const sizes = ["11", "12", "13", "14", "16", "18", "20"]

pub const schemes = ["Dark", "Light", "Solarized"]

pub const color_options = [
  "Default", "#e06c75", "#e5a55d", "#e5c07b", "#98c379", "#56b6c2", "#61afef",
  "#c678dd", "#f5f5f5",
]

pub const align_options = [
  "Free", "Top", "Bottom", "Left", "Right", "Client", "Fill",
]

pub const layout_options = ["Free", "Column", "Row"]

// ---------------------------------------------------------------------------
// View data (what the shell displays; built by `ide_ui.snapshot`)
// ---------------------------------------------------------------------------

pub type ProjectItem {
  ProjectItem(id: String, title: String, active: Bool, icon: String)
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

pub type LineItem {
  LineItem(tokens: List(TokenItem))
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

/// One inspector row: `kind` is the display kind ("text", "number", "bool",
/// "choice", "color", "picture", "event"); `value`/`checked`/`index` carry the
/// edited value; blank/mixed values keep the row empty.
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

/// Everything the shell displays, derived from IDE state by `ide_ui.snapshot`.
pub type ShellView {
  ShellView(
    /// Where every pane sits for this window size.
    layout: Layout,
    title: String,
    theme: String,
    status: String,
    path: String,
    /// The pointer's shape over this window (`default`, `grab`, `nwse`, …).
    cursor: String,
    running: Bool,
    /// Per project row, the module that project's app runs ("" = not
    /// runnable). The navigator draws a run button on the row's right end.
    project_apps: List(String),
    /// Module ids whose app window is up: their row's button is a stop button.
    running_modules: List(String),
    code_view: Bool,
    events_tab: Bool,
    hints: Bool,
    has_selection: Bool,
    /// Whether the primary selection's parent lays its children out itself
    /// (`free`): only then do the eight resize grips apply.
    selection_free: Bool,
    selection_label: String,
    can_delete_project: Bool,
    has_project_icon: Bool,
    project_icon: String,
    project_title: String,
    project_path: String,
    project_selected: Bool,
    /// The module window itself is selected: its title bar was clicked, and
    /// the eight handles around the form resize it.
    window_selected: Bool,
    /// The module this project runs, and the modules it could run. Empty means
    /// the project is not runnable and the top bar offers no project button.
    project_app: String,
    project_app_options: List(String),
    settings_open: Bool,
    agent_open: Bool,
    project_dialog_open: Bool,
    mcp_enabled: Bool,
    mcp_port: String,
    mcp_status: String,
    context_open: Bool,
    context_align: Bool,
    context_x: Int,
    context_y: Int,
    selection_count: Int,
    nav_context_open: Bool,
    nav_context_project: Bool,
    popup_open: Bool,
    popup_title: String,
    popup_action: String,
    browser_dir: String,
    browser_name: String,
    font: String,
    font_size: Int,
    scheme_index: Int,
    form_title: String,
    window_x: Int,
    window_y: Int,
    projects: List(ProjectItem),
    modules: List(ModuleItem),
    tabs: List(TabItem),
    controls: List(ControlItem),
    canvas: List(ControlDesc),
    canvas_selection: #(Int, Int, Int, Int),
    /// Each selected control's box in canvas coordinates: a multi-selection
    /// draws one outline per member, so what is in it is visible.
    selection_boxes: List(#(Int, Int, Int, Int)),
    /// Active marquee/placement rectangle, normalized, canvas-local.
    canvas_marquee: #(Bool, Int, Int, Int, Int),
    /// The container a drag would drop into, canvas-local: the drag answers
    /// "which parent?" with an outline while the pointer is still down.
    canvas_drop: #(Bool, Int, Int, Int, Int),
    props: List(PropItem),
    events: List(PropItem),
    completions: List(CompletionItem),
    diagnostics: List(DiagItem),
    browser_items: List(BrowserItem),
    code: List(LineItem),
    code_source: String,
    code_handler: String,
    console_lines: List(String),
  )
}

/// A view with nothing in it: the diff baseline (`ide_ui.empty_snapshot`).
pub fn empty_view() -> ShellView {
  ShellView(
    layout: layout(window_width, window_height),
    title: "",
    theme: "dark",
    status: "",
    path: "",
    cursor: "default",
    running: False,
    project_apps: [],
    running_modules: [],
    code_view: False,
    events_tab: False,
    hints: False,
    has_selection: False,
    selection_free: False,
    selection_label: "",
    can_delete_project: False,
    has_project_icon: False,
    project_icon: "",
    project_title: "",
    project_path: "",
    project_selected: False,
    window_selected: False,
    project_app: "",
    project_app_options: [],
    settings_open: False,
    agent_open: False,
    project_dialog_open: False,
    mcp_enabled: False,
    mcp_port: "",
    mcp_status: "",
    context_open: False,
    context_align: False,
    context_x: 0,
    context_y: 0,
    selection_count: 0,
    nav_context_open: False,
    nav_context_project: False,
    popup_open: False,
    popup_title: "",
    popup_action: "",
    browser_dir: "",
    browser_name: "",
    font: "monospace",
    font_size: 13,
    scheme_index: 0,
    form_title: "",
    window_x: 32,
    window_y: 40,
    projects: [],
    modules: [],
    tabs: [],
    controls: [],
    canvas: [],
    canvas_selection: #(0, 0, 0, 0),
    selection_boxes: [],
    canvas_marquee: #(False, 0, 0, 0, 0),
    canvas_drop: #(False, 0, 0, 0, 0),
    props: [],
    events: [],
    completions: [],
    diagnostics: [],
    browser_items: [],
    code: [],
    code_source: "",
    code_handler: "",
    console_lines: [],
  )
}

pub fn window_title(project_title: String) -> String {
  "Campy IDE — " <> project_title
}

/// The wire id of one shell section (the module doc's glossary names them).
pub fn section_id(name: String) -> Int {
  campy_form.wire_id(name)
}

// ---------------------------------------------------------------------------
// Row vocabulary
// ---------------------------------------------------------------------------

/// How an inspector row is edited.
pub type RowKind {
  TextRow
  NumberRow
  BoolRow
  ChoiceRow
  OpenRow
}

/// The editor kind for one inspector key. Fixed per key so the row control's
/// kind never changes (the diff would otherwise need a reload).
pub fn row_kind(key: String) -> RowKind {
  case key {
    "x"
    | "y"
    | "w"
    | "h"
    | "width"
    | "height"
    | "border"
    | "transparency"
    | "current-index"
    | "minimum"
    | "maximum"
    | "value" -> NumberRow
    "enabled" | "visible" | "checked" | "read-only" | "line-numbers" -> BoolRow
    "color" | "align" | "layout" -> ChoiceRow
    "picture" -> OpenRow
    "changed" | "clicked" | "edited" | "selected" | "toggled" -> OpenRow
    _ -> TextRow
  }
}

/// The `PropItem.kind` display string for one key ("event" for event rows).
pub fn row_kind_key(key: String) -> String {
  case list.contains(event_keys(), key) {
    True -> "event"
    False ->
      case row_kind(key) {
        TextRow -> "text"
        NumberRow -> "number"
        BoolRow -> "bool"
        ChoiceRow -> "choice"
        OpenRow -> "picture"
      }
  }
}

/// The label shown for one inspector key: IDE keys first, then the label the
/// CCL catalog declares for the property or event.
pub fn row_label(key: String) -> String {
  case key {
    "name" -> "Name"
    "text" -> "Text"
    "title" -> "Title"
    "width" -> "Width"
    "height" -> "Height"
    "x" -> "X"
    "y" -> "Y"
    "w" -> "W"
    "h" -> "H"
    "border" -> "Border"
    "transparency" -> "Transp. %"
    "color" -> "Color"
    "align" -> "Align"
    "layout" -> "Layout"
    "enabled" -> "Enabled"
    "visible" -> "Visible"
    "picture" -> "Picture"
    "changed" -> "OnChange"
    "clicked" -> "OnClicked"
    "edited" -> "OnEdited"
    "selected" -> "OnSelect"
    "toggled" -> "OnToggle"
    _ -> catalog_label(key)
  }
}

fn catalog_label(key: String) -> String {
  campy_ccl.all()
  |> list.find_map(fn(component) {
    case list.find(component.properties, fn(property) { property.key == key }) {
      Ok(property) -> Ok(property.label)
      Error(_) ->
        case list.find(component.events, fn(event) { event.key == key }) {
          Ok(event) -> Ok(event.label)
          Error(_) -> Error(Nil)
        }
    }
  })
  |> result.unwrap(key)
}

fn catalog_property_keys() -> List(String) {
  campy_ccl.all()
  |> list.flat_map(fn(component) {
    list.map(component.properties, fn(property) { property.key })
  })
  |> list.unique
}

fn catalog_event_keys() -> List(String) {
  campy_ccl.all()
  |> list.flat_map(fn(component) {
    list.map(component.events, fn(event) { event.key })
  })
  |> list.unique
}

/// The property-row pool, in a stable order: the IDE's own rows first, then the
/// CCL schema keys, then the window rows.
pub fn prop_keys() -> List(String) {
  list.unique(list.append(
    [
      "name", "text", "picture", "transparency", "x", "y", "w", "h", "color",
      "align", "layout", "parent", "border", "enabled", "visible",
    ],
    list.append(catalog_property_keys(), ["title", "width", "height"]),
  ))
}

/// The event-row pool.
pub fn event_keys() -> List(String) {
  list.unique(list.append(catalog_event_keys(), []))
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

/// The whole IDE window: one root (id 0) whose children are the shell sections
/// and the hidden dialogs/overlays.
pub fn desc(view: ShellView) -> List(ControlDesc) {
  let l = view.layout
  let root =
    node("ide-root", "panel", "", 0, 0, l.width, l.height)
    |> with_class("campy-ide-root")
    |> with_children(list.append(
      [menu_bar(view), rule("menu-rule", 0, l.menu_h, l.width, 1)],
      list.append(
        [navigator(view)],
        list.append(centre(view), [
          right_pane(view),
          status_bar(view),
          settings_dialog(view),
          agent_dialog(view),
          project_dialog(view),
          browser_backdrop(view),
          browser_dialog(view),
          context_menu(view),
          align_menu(view),
          nav_context(view),
        ]),
      ),
    ))
  [ControlDesc(..root, id: campy_form.window_id)]
}

// --- menu bar ---------------------------------------------------------------

fn menu_bar(view: ShellView) -> ControlDesc {
  let l = view.layout
  node("menu-bar", "panel", "", 0, 0, l.width, l.menu_h)
  |> with_class("campy-menubar")
  |> with_props([layout_prop("free")])
  |> with_children([
    menu("menu-file", "File", 8, 58, file_menu(), "New, open, save"),
    menu("menu-edit", "Edit", 70, 58, edit_menu(), "Undo, redo, clipboard"),
    menu("menu-settings", "Settings", 132, 90, settings_menu(), "Editor, agent"),
    palette(view),
  ])
}

/// Run buttons laid over the navigator rows: one at the right end of each
/// project row whose project has an app, and one on each module row. A running
/// app's button is red and stops it; several can run at once.
fn nav_run_buttons(view: ShellView) -> List(ControlDesc) {
  let l = view.layout
  let project_rows =
    list.index_map(indices(project_run_pool), fn(index, _) {
      let app = at_string(view.project_apps, index)
      run_row_button(
        "run-p:" <> int.to_string(index),
        l.nav_w - 32,
        projects_row_y + index * nav_row,
        app,
        list.contains(view.running_modules, app),
      )
      |> shown(app != "" && index < list.length(view.project_apps))
    })
  let module_rows =
    list.index_map(indices(module_run_pool), fn(index, _) {
      let id = case list.drop(view.modules, index) {
        [module, ..] -> module.id
        [] -> ""
      }
      run_row_button(
        "run-m:" <> int.to_string(index),
        l.nav_w - 32,
        modules_row_y + index * nav_row,
        id,
        list.contains(view.running_modules, id),
      )
      |> shown(id != "")
    })
  list.append(project_rows, module_rows)
}

/// The run/stop button of one navigator row, or an inert placeholder slot
/// (shown only when its row exists).
fn run_row_button(
  name: String,
  x: Int,
  y: Int,
  target: String,
  running: Bool,
) -> ControlDesc {
  node(
    name,
    "button",
    case running {
      True -> "■"
      False -> "▶"
    },
    x,
    y + 1,
    22,
    nav_row - 2,
  )
  |> with_class("campy-nav-run")
  |> with_class(case running {
    True -> "campy-stop"
    False -> "campy-run"
  })
  |> with_props([
    hint_prop(case running {
      True -> "Stop this app"
      False -> "Run this app"
    }),
    #("run-target", WireText(target)),
  ])
}

/// Resolves a navigator run button's wire id back to its name. The ids are
/// derived (one per pool slot), like the module tabs'.
pub fn nav_run_name(id: Int) -> Option(String) {
  let names =
    list.append(
      list.map(indices(project_run_pool), fn(index) {
        "run-p:" <> int.to_string(index)
      }),
      list.map(indices(module_run_pool), fn(index) {
        "run-m:" <> int.to_string(index)
      }),
    )
  case list.find(names, fn(name) { campy_form.wire_id(name) == id }) {
    Ok(name) -> Some(name)
    Error(_) -> None
  }
}

fn at_string(items: List(String), index: Int) -> String {
  case list.drop(items, index) {
    [first, ..] -> first
    [] -> ""
  }
}

fn menu(
  name: String,
  label: String,
  x: Int,
  w: Int,
  items: List(String),
  hint: String,
) -> ControlDesc {
  node(name, "menu", label, x, 7, w, 32)
  |> with_class("campy-menu")
  |> with_props([hint_prop(hint), model_prop(list.map(items, WireText))])
}

fn file_menu() -> List(String) {
  [
    "New project    Ctrl+N",
    "New module    Ctrl+Shift+N",
    separator(),
    "Open…    Ctrl+O",
    "Save    Ctrl+S",
    "Save As…    Ctrl+Shift+S",
    separator(),
    "Quit    Ctrl+Q",
  ]
}

fn edit_menu() -> List(String) {
  [
    "Undo    Ctrl+Z",
    "Redo    Ctrl+Shift+Z",
    separator(),
    "Copy component    Ctrl+C",
    "Cut component    Ctrl+X",
    "Paste component    Ctrl+V",
    separator(),
    "Delete component    Del",
    separator(),
    "Bring to front",
    "Move to back",
    separator(),
    "Update running app    F7",
    "Reload Campy code    F6",
  ]
}

fn settings_menu() -> List(String) {
  ["Editor…", "Agent…"]
}

fn separator() -> String {
  "—"
}

fn palette(view: ShellView) -> ControlDesc {
  let tiles =
    campy_ccl.all()
    |> list.index_map(fn(component: campy_ccl.Component, index: Int) {
      node(
        "tile:" <> component.key,
        "button",
        component.icon,
        3 + index * 48,
        2,
        44,
        34,
      )
      |> with_class("campy-palette-tile")
      |> with_props([
        #("kind", WireText(component.key)),
        #(
          "label",
          WireText(
            component.label <> " — click, then drag on the form to place it",
          ),
        ),
        hint_prop(component.label),
      ])
    })
  node("palette", "panel", "", 228, 2, view.layout.width - 320, 42)
  |> with_class("campy-palette")
  |> with_props([layout_prop("free")])
  |> with_children(tiles)
}

// --- navigator --------------------------------------------------------------

/// The navigator's list rows: the renderer's `VirtualList` row size, and the
/// tops of the two lists under their titles. The row buttons are siblings of
/// the list (a list's rows are built by the renderer), so they are positioned
/// from these.
const nav_row = 24

const projects_row_y = 40

const modules_row_y = 196

/// How many rows can carry a button, so the document's shape stays fixed.
const project_run_pool = 8

const module_run_pool = 12

fn navigator(view: ShellView) -> ControlDesc {
  let l = view.layout
  node("nav", "panel", "", 0, l.body_y, l.nav_w, l.nav_h)
  |> with_class("campy-nav")
  |> with_props([layout_prop("free")])
  |> with_children(list.append(
    [
      node("nav-projects-title", "label", "Projects", 8, 8, 90, 28)
        |> with_class("campy-title"),
      node("project-delete", "button", "⌫", l.nav_w - 66, 10, 26, 24)
        |> with_class("campy-icon-button")
        |> with_props([hint_prop("Remove project")])
        |> enabled_as(view.can_delete_project),
      node("project-add", "button", "+", l.nav_w - 34, 10, 26, 24)
        |> with_class("campy-icon-button")
        |> with_props([hint_prop("Add project")]),
      list_node(
        "projects-nav",
        8,
        40,
        l.nav_w - 16,
        110,
        list.map(view.projects, fn(item: ProjectItem) {
          WireStruct([
            #("text", WireText(item.title)),
            #("id", WireText(item.id)),
            #("active", WireBool(item.active)),
            #("icon", WireText(item.icon)),
          ])
        }),
      )
        |> with_class("campy-nav-list")
        |> with_props([hint_prop("Projects — click one to switch to it")]),
      rule("nav-rule", 8, 156, l.nav_w - 16, 1),
      node("nav-modules-title", "label", "Modules", 8, 162, 90, 28)
        |> with_class("campy-title"),
      node("module-add", "button", "+", l.nav_w - 34, 164, 26, 26)
        |> with_class("campy-icon-button")
        |> with_props([hint_prop("New module")]),
      list_node(
        "modules-nav",
        8,
        196,
        l.nav_w - 16,
        l.nav_h - 208,
        list.map(view.modules, fn(item: ModuleItem) {
          WireStruct([
            #("text", WireText(item.name)),
            #("id", WireText(item.id)),
            #("active", WireBool(item.active)),
          ])
        }),
      )
        |> with_class("campy-nav-list")
        |> with_props([hint_prop("Modules — click one to open it here")]),
    ],
    nav_run_buttons(view),
  ))
}

// --- centre -----------------------------------------------------------------

fn centre(view: ShellView) -> List(ControlDesc) {
  let l = view.layout
  [
    tab_strip(view),
    canvas(view),
    rule("canvas-rule", l.canvas_x, l.rule_y, l.centre_w, 1)
      |> shown(!view.code_view),
    node(
      "view-toggle",
      "button",
      toggle_glyph(view),
      l.right_x - 45,
      l.canvas_y + 7,
      36,
      36,
    )
      |> with_class("campy-view-toggle")
      |> with_props([hint_prop("Toggle form/code (Ctrl+Tab)")]),
    node(
      "code-title",
      "label",
      "Handler code",
      l.centre_x + 10,
      l.canvas_y + 8,
      100,
      20,
    )
      |> with_class("campy-code-title")
      |> shown(view.code_view),
    node(
      "code-handler",
      "label",
      view.code_handler,
      l.centre_x + 114,
      l.canvas_y + 8,
      400,
      20,
    )
      |> with_class("campy-code-handler")
      |> shown(view.code_view),
    node(
      "code-view",
      "code_editor",
      view.code_source,
      l.canvas_x,
      l.canvas_y + 32,
      l.canvas_w,
      l.canvas_h + 2,
    )
      |> with_class("campy-code")
      |> with_props([
        #("language", WireText("gleam")),
        #("line-numbers", WireBool(True)),
        #("read-only", WireBool(False)),
      ])
      |> shown(view.code_view),
    list_node(
      "completions",
      l.canvas_x + { l.centre_w - 280 } / 2,
      l.canvas_y + 221,
      280,
      184,
      list.map(view.completions, fn(item: CompletionItem) {
        WireStruct([
          #("text", WireText(item.label)),
          #("detail", WireText(item.detail)),
          #("insert", WireText(item.insert)),
        ])
      }),
    )
      |> with_class("campy-completions")
      |> shown(view.code_view && !list.is_empty(view.completions)),
    console_pane(view),
  ]
}

/// The open modules, as a strip of tabs. One button per module rather than a
/// `list`: the only list the platform offers is vertical, and a tab strip is
/// not. The module id rides the control name (`tab:<module id>`), so a click
/// names the module the loop should switch to.
fn tab_strip(view: ShellView) -> ControlDesc {
  let tabs =
    view.tabs
    |> list.index_map(fn(item: TabItem, index: Int) {
      node("tab:" <> item.id, "button", item.name, 2 + index * 136, 4, 132, 26)
      |> with_class("campy-module-tab")
      |> with_class_if("campy-tab-on", item.active)
      |> with_props([hint_prop("Switch to " <> item.name)])
    })
  // One close button per tab, at its right end. Closing a tab leaves the
  // module in the navigator; it is the tab that goes.
  let closes =
    view.tabs
    |> list.index_map(fn(item: TabItem, index: Int) {
      node(
        "tab-close:" <> item.id,
        "button",
        "×",
        2 + index * 136 + 108,
        7,
        20,
        20,
      )
      |> with_class("campy-tab-x")
      |> with_props([hint_prop("Close " <> item.name <> " (Ctrl+F4)")])
    })
  node(
    "tab-strip",
    "panel",
    "",
    view.layout.centre_x,
    view.layout.tabstrip_y,
    view.layout.centre_w,
    view.layout.tabstrip_h,
  )
  |> with_class("campy-tab-strip")
  |> with_props([layout_prop("free")])
  |> with_children(list.append(tabs, closes))
}

fn toggle_glyph(view: ShellView) -> String {
  case view.code_view {
    True -> "▦"
    False -> "⌨"
  }
}

fn canvas(view: ShellView) -> ControlDesc {
  let #(form_w, form_h) = canvas_size(view.canvas)
  let form_children = case view.canvas {
    [root, ..] -> root.children
    [] -> []
  }
  let #(sx, sy, sw, sh) = view.canvas_selection
  let #(marquee, mx, my, mw, mh) = view.canvas_marquee
  let #(dropping, dx, dy, dw, dh) = view.canvas_drop
  node(
    "canvas",
    "surface",
    "",
    view.layout.canvas_x,
    view.layout.canvas_y,
    view.layout.canvas_w,
    view.layout.canvas_h,
  )
  |> with_class("campy-canvas")
  |> with_props([
    layout_prop("free"),
    hint_prop(
      "Click to select · drag to move · Ctrl-drag to marquee · right-click for the menu",
    ),
  ])
  |> shown(!view.code_view)
  |> with_children(list.append(
    [
      node(
        "canvas-title",
        "label",
        view.form_title,
        view.window_x,
        view.window_y,
        form_w,
        form_title_height,
      )
        |> with_class("campy-canvas-title")
        |> with_props([hint_prop("Drag to move the component window")]),
      node(
        "canvas-form",
        "panel",
        view.form_title,
        view.window_x,
        view.window_y + form_title_height,
        form_w,
        form_h,
      )
        |> with_class("campy-canvas-form")
        |> with_props(form_props(view.canvas))
        |> with_children(form_children),
      node("drop-target", "panel", "", dx, dy, dw, dh)
        |> with_class("campy-drop")
        |> shown(dropping),
      node("selection-rect", "panel", "", sx, sy, sw, sh)
        |> with_class("campy-selected")
        |> shown(view.has_selection || view.window_selected),
    ],
    list.append(
      selection_members(view),
      list.append(grips(view), [
        node("marquee-rect", "panel", "", mx, my, mw, mh)
        |> with_class("campy-marquee")
        |> shown(marquee),
      ]),
    ),
  ))
}

/// One outline per selected control, from a fixed pool: a selection must not
/// change the document's shape. Only a multi-selection needs them — a single
/// one is the union box itself.
fn selection_members(view: ShellView) -> List(ControlDesc) {
  let members = view.selection_boxes
  let count = list.length(members)
  list.map(indices(member_pool), fn(index: Int) {
    let #(x, y, w, h) = option.unwrap(at(members, index), #(0, 0, 0, 0))
    node("member-" <> int.to_string(index), "panel", "", x, y, w, h)
    |> with_class("campy-member")
    |> shown(count > 1 && index < count)
  })
}

/// The eight grips around the primary selection, and the module window's own
/// corner grip. Both sets are always described and only shown or hidden: a
/// selection must not change the document's *shape*, or every click would need
/// a fresh `LoadUi` instead of a handful of geometry ops.
fn grips(view: ShellView) -> List(ControlDesc) {
  let #(sx, sy, sw, sh) = view.canvas_selection
  let #(form_w, form_h) = canvas_size(view.canvas)
  // A selected window takes the eight handles itself, around the whole form.
  case view.window_selected {
    True -> {
      let wx = view.window_x
      let wy = view.window_y + form_title_height
      let mx = wx + form_w / 2
      let my = wy + form_h / 2
      [
        grip("nw", wx, wy),
        grip("n", mx, wy),
        grip("ne", wx + form_w, wy),
        grip("w", wx, my),
        grip("e", wx + form_w, my),
        grip("sw", wx, wy + form_h),
        grip("s", mx, wy + form_h),
        grip("se", wx + form_w, wy + form_h),
      ]
    }
    False -> {
      let mx = sx + sw / 2
      let my = sy + sh / 2
      let selected = view.has_selection && view.selection_free
      [
        grip("nw", sx, sy) |> shown(selected),
        grip("n", mx, sy) |> shown(selected),
        grip("ne", sx + sw, sy) |> shown(selected),
        grip("w", sx, my) |> shown(selected),
        grip("e", sx + sw, my) |> shown(selected),
        grip("sw", sx, sy + sh) |> shown(selected),
        grip("s", mx, sy + sh) |> shown(selected),
        grip("se", sx + sw, sy + sh) |> shown(selected),
        grip(
          "window",
          view.window_x + form_w,
          view.window_y + form_title_height + form_h,
        )
          |> shown(!view.has_selection),
      ]
    }
  }
}

fn indices(count: Int) -> List(Int) {
  indices_from(0, count, [])
}

fn indices_from(index: Int, count: Int, acc: List(Int)) -> List(Int) {
  case index >= count {
    True -> list.reverse(acc)
    False -> indices_from(index + 1, count, [index, ..acc])
  }
}

fn grip(name: String, cx: Int, cy: Int) -> ControlDesc {
  let half = grip_size / 2
  node("grip-" <> name, "panel", "", cx - half, cy - half, grip_size, grip_size)
  |> with_class(case name {
    "window" -> "campy-grip campy-grip-window"
    _ -> "campy-grip"
  })
}

// The form root's layout props, so the renderer enters the form's own
// Free/Column/Row mode at the canvas form.
fn form_props(document: List(ControlDesc)) -> List(#(String, WireValue)) {
  case document {
    [root, ..] ->
      list.filter(root.props, fn(prop) {
        let #(key, _) = prop
        key == "layout" || key == "border"
      })
    [] -> [layout_prop("free"), #("border", WireInt(0))]
  }
}

fn canvas_size(document: List(ControlDesc)) -> #(Int, Int) {
  case document {
    [root, ..] -> #(root.w, root.h)
    [] -> #(0, 0)
  }
}

// --- console ----------------------------------------------------------------

fn console_pane(view: ShellView) -> ControlDesc {
  let l = view.layout
  node(
    "console-pane",
    "panel",
    "",
    l.centre_x,
    l.console_y,
    l.console_w,
    l.console_h,
  )
  |> with_class("campy-console-pane")
  |> with_props([layout_prop("free")])
  |> with_children([
    node("console-title", "label", "Console", 10, 4, 70, 24)
      |> with_class("campy-console-title"),
    node(
      "console-state",
      "label",
      case view.running {
        True -> "running"
        False -> "stopped"
      },
      84,
      4,
      80,
      24,
    )
      |> with_class("campy-console-state"),
    node("console-clear", "button", "Clear", l.console_w - 68, 2, 60, 26)
      |> with_class("campy-console-clear")
      |> with_props([hint_prop("Clear console")]),
    node("console", "console", "", 0, 30, l.console_w, l.console_h - 30)
      |> with_class("campy-console"),
  ])
}

// --- right pane -------------------------------------------------------------

fn right_pane(view: ShellView) -> ControlDesc {
  let l = view.layout
  node("right-pane", "panel", "", l.right_x, l.body_y, l.right_w, l.right_h)
  |> with_class("campy-inspector-pane")
  |> with_props([layout_prop("free")])
  |> with_children([
    node("insp-tab-properties", "button", "⚙ Properties", 8, 8, 150, 30)
      |> with_class("campy-insp-tab")
      |> with_class_if("campy-tab-on", !view.events_tab)
      |> with_props([hint_prop("Properties")]),
    node("insp-tab-events", "button", "⚡ Events", 162, 8, 150, 30)
      |> with_class("campy-insp-tab")
      |> with_class_if("campy-tab-on", view.events_tab)
      |> with_props([hint_prop("Events")]),
    rule("insp-rule", 0, 42, 320, 1),
    node("insp-selection", "label", view.selection_label, 8, 50, 240, 32)
      |> with_class("campy-insp-selection"),
    node("insp-delete", "button", "⌫", 272, 50, 40, 28)
      |> with_class("campy-icon-button")
      |> with_props([hint_prop("Delete (Del)")])
      |> shown(view.has_selection),
    project_panel(view),
    inspector("inspector", view.props, !view.events_tab, False, view),
    inspector("inspector-events", view.events, view.events_tab, True, view),
  ])
}

fn project_panel(view: ShellView) -> ControlDesc {
  node(
    "project-panel",
    "panel",
    "",
    0,
    88,
    view.layout.right_w,
    view.layout.pane_h,
  )
  |> with_class("campy-project-panel")
  |> with_props([layout_prop("free")])
  |> shown(view.project_selected)
  |> with_children([
    node("project-icon", "picture", "", 8, 8, 48, 48)
      |> with_class("campy-project-icon")
      |> with_props([#("source", WireImage(view.project_icon))])
      |> shown(view.has_project_icon),
    node("project-icon-glyph", "label", "▤", 8, 8, 48, 48)
      |> with_class("campy-project-icon-glyph")
      |> shown(!view.has_project_icon),
    node("project-icon-choose", "button", "Choose icon…", 64, 8, 150, 26)
      |> with_class("campy-project-icon-action")
      |> with_props([hint_prop("Choose an image for this project")]),
    node("project-icon-clear", "button", "Clear icon", 64, 38, 150, 26)
      |> with_class("campy-project-icon-action")
      |> with_props([hint_prop("Remove icon")]),
    node("project-title-label", "label", "Title", 8, 70, 64, 28)
      |> with_class("campy-field-label"),
    node("project-title", "edit", view.project_title, 76, 70, 236, 28)
      |> with_class("campy-field-edit"),
    node("project-path-label", "label", "Path", 8, 102, 64, 28)
      |> with_class("campy-field-label"),
    node("project-path", "label", view.project_path, 76, 102, 236, 28)
      |> with_class("campy-field-text"),
    node("project-app-label", "label", "App", 8, 134, 64, 28)
      |> with_class("campy-field-label"),
    node("project-app", "combo", view.project_app, 76, 134, 236, 28)
      |> with_class("campy-field-edit")
      |> with_props([
        model_prop(list.map(view.project_app_options, WireText)),
        hint_prop("The module this project runs as an app"),
      ]),
  ])
}

fn inspector(
  name: String,
  items: List(PropItem),
  active: Bool,
  is_events: Bool,
  view: ShellView,
) -> ControlDesc {
  let keys = case is_events {
    True -> event_keys()
    False -> prop_keys()
  }
  let rows =
    keys
    |> list.flat_map(fn(key: String) {
      let slot = index_of_item(items, key)
      inspector_row(key, item_at(items, slot), slot, is_events)
    })
  node(name, "panel", "", 0, 88, view.layout.right_w, view.layout.pane_h)
  |> with_class("campy-inspector")
  |> with_props([layout_prop("free")])
  |> shown(active && !view.project_selected)
  |> with_children(rows)
}

fn inspector_row(
  key: String,
  item: Option(PropItem),
  slot: Option(Int),
  is_events: Bool,
) -> List(ControlDesc) {
  let row_name = "insp:" <> key
  let visible = slot != None
  let y = case slot {
    Some(index) -> 8 + index * 30
    None -> 0
  }
  let label =
    node(row_name <> ":label", "label", row_label(key), 8, y, 96, 28)
    |> with_class("campy-insp-label")
    |> shown(visible)
  let editor = case row_kind(key) {
    TextRow | NumberRow ->
      node(row_name, "edit", item_text(item), 108, y, 204, 28)
      |> with_class("campy-insp-text")
    BoolRow ->
      node(row_name, "checkbox", "", 108, y, 204, 28)
      |> with_class("campy-insp-bool")
      |> with_props([#("checked", WireBool(item_checked(item)))])
    ChoiceRow ->
      node(row_name, "combo", option_text(item), 108, y, 204, 28)
      |> with_class("campy-insp-choice")
      |> with_props([model_prop(choice_options(key, item))])
    OpenRow ->
      node(row_name, "button", item_text(item), 108, y, 204, 28)
      |> with_class(case is_events {
        True -> "campy-insp-event"
        False -> "campy-insp-open"
      })
  }
  let hint = case list.contains(event_keys(), key) {
    True -> "Open the " <> row_label(key) <> " handler"
    False ->
      case row_kind(key) {
        BoolRow -> "Toggle " <> row_label(key)
        ChoiceRow -> "Choose " <> row_label(key)
        NumberRow -> "Set " <> row_label(key)
        _ -> "Edit " <> row_label(key)
      }
  }
  [
    label,
    ControlDesc(
      ..editor,
      props: list.append(editor.props, [hint_prop(hint)]),
      visible: visible,
      x: case visible {
        True -> 108
        False -> 0
      },
      w: case visible {
        True -> 204
        False -> 0
      },
      h: case visible {
        True -> 28
        False -> 0
      },
    ),
  ]
}

fn item_at(items: List(PropItem), slot: Option(Int)) -> Option(PropItem) {
  case slot {
    Some(index) -> at(items, index)
    None -> None
  }
}

fn index_of_item(items: List(PropItem), key: String) -> Option(Int) {
  index_of_loop(items, key, 0)
}

fn index_of_loop(
  items: List(PropItem),
  key: String,
  index: Int,
) -> Option(Int) {
  case items {
    [] -> None
    [first, ..rest] ->
      case first.key == key {
        True -> Some(index)
        False -> index_of_loop(rest, key, index + 1)
      }
  }
}

fn item_text(item: Option(PropItem)) -> String {
  case item {
    Some(value) -> value.value
    None -> ""
  }
}

fn item_checked(item: Option(PropItem)) -> Bool {
  case item {
    Some(value) -> value.checked
    None -> False
  }
}

fn option_text(item: Option(PropItem)) -> String {
  case item {
    Some(value) ->
      case value.index >= 0 {
        True -> at(value.options, value.index) |> option.unwrap("")
        False -> ""
      }
    None -> ""
  }
}

fn choice_options(key: String, item: Option(PropItem)) -> List(WireValue) {
  let options = case item {
    Some(value) ->
      case value.options {
        [] -> default_options(key)
        options -> options
      }
    None -> default_options(key)
  }
  list.map(options, WireText)
}

fn default_options(key: String) -> List(String) {
  case key {
    "color" -> color_options
    "align" -> align_options
    "layout" -> layout_options
    _ -> []
  }
}

fn at(items: List(a), index: Int) -> Option(a) {
  case items {
    [] -> None
    [first, ..rest] ->
      case index <= 0 {
        True -> Some(first)
        False -> at(rest, index - 1)
      }
  }
}

// --- status bar -------------------------------------------------------------

fn status_bar(view: ShellView) -> ControlDesc {
  let l = view.layout
  node("status-bar", "panel", "", 0, l.status_y, l.width, l.status_h)
  |> with_class("campy-status-bar")
  |> with_props([layout_prop("free")])
  |> with_children([
    node("status", "label", view.status, 10, 3, 700, 20)
      |> with_class("campy-status"),
    node("status-path", "label", view.path, l.width - 560, 3, 550, 20)
      |> with_class("campy-status-path"),
  ])
}

// --- dialogs and overlays ---------------------------------------------------

fn settings_dialog(view: ShellView) -> ControlDesc {
  node(
    "settings-panel",
    "panel",
    "",
    centre_x(view, 520),
    centre_y(view, 330),
    520,
    330,
  )
  |> with_class("campy-dialog")
  |> with_props([layout_prop("free")])
  |> shown(view.settings_open)
  |> with_children([
    node("settings-title", "label", "Editor settings", 18, 16, 480, 24)
      |> with_class("campy-dialog-title"),
    node("settings-font-label", "label", "Font", 18, 56, 110, 32)
      |> with_class("campy-dialog-label"),
    node("settings-font", "combo", view.font, 136, 56, 366, 32)
      |> with_class("campy-dialog-choice")
      |> with_props([
        model_prop(list.map(fonts, WireText)),
        hint_prop("The editor and console typeface"),
      ]),
    node("settings-size-label", "label", "Font size", 18, 96, 110, 32)
      |> with_class("campy-dialog-label"),
    node(
      "settings-size",
      "combo",
      int.to_string(view.font_size),
      136,
      96,
      366,
      32,
    )
      |> with_class("campy-dialog-choice")
      |> with_props([
        model_prop(list.map(sizes, WireText)),
        hint_prop("The editor's type size"),
      ]),
    node("settings-scheme-label", "label", "Color scheme", 18, 136, 110, 32)
      |> with_class("campy-dialog-label"),
    node(
      "settings-scheme",
      "combo",
      at(schemes, view.scheme_index) |> option.unwrap("Dark"),
      136,
      136,
      366,
      32,
    )
      |> with_class("campy-dialog-choice")
      |> with_props([
        model_prop(list.map(schemes, WireText)),
        hint_prop("Dark, light or solarized"),
      ]),
    node("settings-hints", "checkbox", "Show UI hints", 136, 176, 366, 32)
      |> with_class("campy-dialog-check")
      |> with_props([
        #("checked", WireBool(view.hints)),
        hint_prop("Enable button tooltips and palette hints"),
      ]),
    node("settings-close", "button", "Close", 18, 270, 100, 32)
      |> with_class("campy-dialog-primary")
      |> with_props([hint_prop("Close the settings dialog")]),
  ])
}

fn agent_dialog(view: ShellView) -> ControlDesc {
  node(
    "agent-panel",
    "panel",
    "",
    centre_x(view, 560),
    centre_y(view, 300),
    560,
    300,
  )
  |> with_class("campy-dialog")
  |> with_props([layout_prop("free")])
  |> shown(view.agent_open)
  |> with_children([
    node("agent-title", "label", "Agent settings", 18, 16, 520, 24)
      |> with_class("campy-dialog-title"),
    node("agent-mcp", "checkbox", "Enable MCP server", 18, 52, 520, 32)
      |> with_class("campy-dialog-check")
      |> with_props([
        #("checked", WireBool(view.mcp_enabled)),
        hint_prop("Expose Campy tools over local MCP"),
      ]),
    node("agent-port-label", "label", "Port", 18, 92, 110, 32)
      |> with_class("campy-dialog-label"),
    node("agent-port", "edit", view.mcp_port, 136, 92, 400, 32)
      |> with_class("campy-dialog-edit"),
    node("agent-status", "label", view.mcp_status, 18, 132, 520, 20)
      |> with_class("campy-dialog-text"),
    node(
      "agent-endpoint",
      "label",
      "Endpoint: http://127.0.0.1:" <> view.mcp_port <> "/mcp",
      18,
      156,
      520,
      20,
    )
      |> with_class("campy-dialog-text"),
    node(
      "agent-note",
      "label",
      "Disabled by default. The server listens on localhost only.",
      18,
      180,
      520,
      20,
    )
      |> with_class("campy-dialog-text"),
    node("agent-close", "button", "Close", 18, 248, 100, 32)
      |> with_class("campy-dialog-primary")
      |> with_props([hint_prop("Close the agent settings")]),
  ])
}

fn project_dialog(view: ShellView) -> ControlDesc {
  node(
    "project-dialog",
    "panel",
    "",
    centre_x(view, 460),
    centre_y(view, 240),
    460,
    240,
  )
  |> with_class("campy-dialog")
  |> with_props([layout_prop("free")])
  |> shown(view.project_dialog_open)
  |> with_children([
    node("project-dialog-title", "label", "Projects", 18, 16, 420, 24)
      |> with_class("campy-dialog-title"),
    node(
      "project-dialog-body",
      "label",
      "Create a new project or open an existing project into this workspace.",
      18,
      48,
      420,
      32,
    )
      |> with_class("campy-dialog-text"),
    node("project-new", "button", "Create new project", 18, 92, 420, 32)
      |> with_class("campy-dialog-primary")
      |> with_props([hint_prop("Create a new project in the workspace")]),
    node("project-open", "button", "Open existing project…", 18, 132, 420, 32)
      |> with_class("campy-dialog-action")
      |> with_props([hint_prop("Open a project file into the workspace")]),
    node("project-dialog-cancel", "button", "Cancel", 18, 188, 100, 32)
      |> with_class("campy-dialog-action")
      |> with_props([hint_prop("Cancel")]),
  ])
}

/// Behind the file dialog: a panel over the whole window so a click meant for
/// the dialog cannot reach the canvas and move a component. It takes the press
/// and does nothing with it.
fn browser_backdrop(view: ShellView) -> ControlDesc {
  let l = view.layout
  node("browser-backdrop", "panel", "", 0, 0, l.width, l.height)
  |> with_class("campy-backdrop")
  |> with_props([layout_prop("free")])
  |> shown(view.popup_open)
}

fn browser_dialog(view: ShellView) -> ControlDesc {
  node(
    "browser-panel",
    "panel",
    "",
    centre_x(view, 520),
    centre_y(view, 420),
    520,
    420,
  )
  |> with_class("campy-dialog")
  |> with_props([layout_prop("free")])
  |> shown(view.popup_open)
  |> with_children([
    node("browser-title", "label", view.popup_title, 16, 12, 480, 24)
      |> with_class("campy-dialog-title"),
    node("browser-home", "button", "⌂", 16, 44, 34, 28)
      |> with_class("campy-dialog-icon")
      |> with_props([hint_prop("Go to the home directory")]),
    node("browser-new-dir", "button", "+ Dir", 56, 44, 54, 28)
      |> with_class("campy-dialog-icon")
      |> with_props([hint_prop("Create a folder named as the Name field")]),
    node("browser-dir", "label", view.browser_dir, 118, 44, 300, 28)
      |> with_class("campy-dialog-text"),
    node("browser-up", "button", "↑", 452, 44, 34, 28)
      |> with_class("campy-dialog-icon")
      |> with_props([hint_prop("Go to the parent directory")]),
    list_node(
      "browser-entries",
      16,
      80,
      488,
      240,
      list.map(view.browser_items, fn(item: BrowserItem) {
        WireStruct([
          #("text", WireText(item.name)),
          #("is-dir", WireBool(item.is_dir)),
        ])
      }),
    )
      |> with_class("campy-dialog-list")
      |> with_props([
        hint_prop("A folder opens; a project file is what Open takes"),
      ]),
    node("browser-name-label", "label", "Name", 16, 328, 60, 28)
      |> with_class("campy-dialog-label"),
    node("browser-name", "edit", view.browser_name, 82, 328, 422, 28)
      |> with_class("campy-dialog-edit")
      |> with_props([#("accept-on-enter", WireBool(True))]),
    node("browser-accept", "button", view.popup_action, 16, 370, 120, 32)
      |> with_class("campy-dialog-primary")
      |> with_props([hint_prop("Confirm")]),
    node("browser-cancel", "button", "Cancel", 144, 370, 120, 32)
      |> with_class("campy-dialog-action")
      |> with_props([hint_prop("Cancel")]),
  ])
}

fn context_menu(view: ShellView) -> ControlDesc {
  node("context-menu", "panel", "", view.context_x, view.context_y, 150, 142)
  |> with_class("campy-context-menu")
  |> shown(view.context_open)
  |> with_children([
    menu_row(
      "ctx-cut",
      "Cut",
      2,
      2,
      view.has_selection,
      "Cut the selected components to the clipboard",
    ),
    menu_row(
      "ctx-copy",
      "Copy",
      2,
      28,
      view.has_selection,
      "Copy the selected components",
    ),
    menu_row(
      "ctx-paste",
      "Paste",
      2,
      54,
      True,
      "Paste the clipboard into the form",
    ),
    menu_row(
      "ctx-delete",
      "Delete",
      2,
      80,
      view.has_selection,
      "Delete the selected components (Del)",
    ),
    menu_row(
      "ctx-align",
      "Align ▸",
      2,
      106,
      view.selection_count > 1,
      "Align the selected components",
    ),
  ])
}

fn align_menu(view: ShellView) -> ControlDesc {
  node(
    "align-menu",
    "panel",
    "",
    view.context_x + 150,
    view.context_y,
    110,
    166,
  )
  |> with_class("campy-context-menu")
  |> shown(view.context_open && view.context_align && view.selection_count > 1)
  |> with_children([
    menu_row(
      "align-left",
      "Left",
      2,
      2,
      True,
      "Line the left edges up with the parent",
    ),
    menu_row(
      "align-right",
      "Right",
      2,
      28,
      True,
      "Line the right edges up with the parent",
    ),
    menu_row(
      "align-center",
      "Center",
      2,
      54,
      True,
      "Centre the components horizontally in the parent",
    ),
    menu_row(
      "align-top",
      "Top",
      2,
      80,
      True,
      "Line the top edges up with the parent",
    ),
    menu_row(
      "align-bottom",
      "Down",
      2,
      106,
      True,
      "Line the bottom edges up with the parent",
    ),
    menu_row(
      "align-middle",
      "Middle",
      2,
      132,
      True,
      "Centre the components vertically in the parent",
    ),
  ])
}

fn nav_context(view: ShellView) -> ControlDesc {
  node("nav-context", "panel", "", 0, 0, 150, 112)
  |> with_class("campy-context-menu")
  |> shown(view.nav_context_open)
  |> with_children([
    menu_row(
      "nav-ctx-remove",
      "Remove",
      2,
      2,
      view.nav_context_project,
      "Remove the project from the workspace (its file stays)",
    ),
    menu_row(
      "nav-ctx-open",
      "Open module",
      2,
      28,
      !view.nav_context_project,
      "Open this module",
    ),
    menu_row(
      "nav-ctx-delete",
      "Delete",
      2,
      54,
      !view.nav_context_project,
      "Delete this module from the project",
    ),
    menu_row(
      "nav-ctx-close-tab",
      "Close tab",
      2,
      80,
      !view.nav_context_project,
      "Close this module’s tab",
    ),
  ])
}

fn menu_row(
  name: String,
  label: String,
  x: Int,
  y: Int,
  active: Bool,
  hint: String,
) -> ControlDesc {
  node(name, "button", label, x, y, 146, 26)
  |> with_class("campy-menu-row")
  |> with_props([hint_prop(hint)])
  |> shown(active)
}

// ---------------------------------------------------------------------------
// Construction helpers
// ---------------------------------------------------------------------------

fn node(
  name: String,
  kind: String,
  text: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> ControlDesc {
  ControlDesc(
    id: campy_form.wire_id(name),
    kind: kind,
    text: text,
    x: x,
    y: y,
    w: w,
    h: h,
    enabled: True,
    visible: True,
    props: [],
    children: [],
  )
}

/// Where a dialog of `width` sits horizontally: centred on the window.
fn centre_x(view: ShellView, width: Int) -> Int {
  { view.layout.width - width } / 2
}

/// Where a dialog of `height` sits vertically: a third of the way down, which
/// keeps it clear of the menu bar at every window size.
fn centre_y(view: ShellView, height: Int) -> Int {
  { view.layout.height - height } / 3
}

fn rule(name: String, x: Int, y: Int, w: Int, h: Int) -> ControlDesc {
  node(name, "panel", "", x, y, w, h)
  |> with_class("campy-rule")
}

fn list_node(
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  items: List(WireValue),
) -> ControlDesc {
  node(name, "list", "", x, y, w, h)
  |> with_props([model_prop(items)])
}

/// Adds a class to the control's single `class` prop, joining with a space
/// where one is already there. One prop rather than one per class: the view
/// diff looks props up by key, so a repeated key reads as a changed value.
fn with_class(desc: ControlDesc, name: String) -> ControlDesc {
  let props =
    list.map(desc.props, fn(prop) {
      case prop {
        #("class", WireText(existing)) -> #(
          "class",
          WireText(existing <> " " <> name),
        )
        other -> other
      }
    })
  ControlDesc(
    ..desc,
    props: case list.any(desc.props, fn(prop) { prop.0 == "class" }) {
      True -> props
      False -> list.append(desc.props, [#("class", WireText(name))])
    },
  )
}

/// The class only where a state says so: the sheet styles the active tab, and
/// an inactive one carries nothing extra.
fn with_class_if(desc: ControlDesc, name: String, on: Bool) -> ControlDesc {
  case on {
    True -> with_class(desc, name)
    False -> desc
  }
}

fn with_props(
  desc: ControlDesc,
  props: List(#(String, WireValue)),
) -> ControlDesc {
  ControlDesc(..desc, props: list.append(desc.props, props))
}

fn with_children(
  desc: ControlDesc,
  children: List(ControlDesc),
) -> ControlDesc {
  ControlDesc(..desc, children: children)
}

fn shown(desc: ControlDesc, visible: Bool) -> ControlDesc {
  ControlDesc(..desc, visible: visible)
}

fn enabled_as(desc: ControlDesc, enabled: Bool) -> ControlDesc {
  ControlDesc(..desc, enabled: enabled)
}

fn model_prop(items: List(WireValue)) -> #(String, WireValue) {
  #("model", WireList(items))
}

fn layout_prop(layout: String) -> #(String, WireValue) {
  #("layout", WireText(layout))
}

fn hint_prop(text: String) -> #(String, WireValue) {
  #("hint", WireText(text))
}
