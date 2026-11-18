//// Thin typed wrappers over the Erlang wx adapter (`campy_wx_native.erl`).
////
//// Widget handles are opaque Erlang terms (`wx_ref` records). They are typed
//// as `Dynamic` here and never inspected; the adapter is the only place that
//// knows wx atoms, options, and record shapes.

import campy_wx/plan.{type TreeItem}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

pub type NativeMessage {
  WxEvent(wx_id: Int, event_type: String)
  /// A picked entry from the editor's jump-to-symbol list: its wx id and the
  /// entry text ("name:line").
  StcJump(wx_id: Int, text: String)
  MouseEvent(wx_id: Int, event_type: String, x: Int, y: Int, control: Bool)
  /// A grid edit carries the edited cell explicitly. Reading the grid cursor
  /// after the event can point at the next cell: Enter moves the cursor before
  /// the application reads it.
  GridEvent(wx_id: Int, row: Int, col: Int, text: String)
  /// A frame-level char_hook key press, normalised to a lower-case code plus
  /// modifier flags. The app maps it to one of its shortcuts.
  KeyEvent(code: String, control: Bool, shift: Bool, alt: Bool)
  /// A frame accelerator (Ctrl+S, Ctrl+1, ...) matched before the focused
  /// control; unlike char_hook it still works inside a wxGrid editor.
  ShortcutEvent(action: String)
  Other(message: Dynamic)
  Idle
}

@external(erlang, "campy_wx_native", "new_app")
pub fn new_app() -> Dynamic

@external(erlang, "campy_wx_native", "destroy_app")
pub fn destroy_app() -> Nil

@external(erlang, "campy_wx_native", "frame")
pub fn frame(id: Int, title: String, width: Int, height: Int) -> Dynamic

@external(erlang, "campy_wx_native", "show")
pub fn show(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "connect")
pub fn connect(ref: Dynamic, kind: String) -> Nil

@external(erlang, "campy_wx_native", "next_message")
pub fn next_message(timeout_ms: Int) -> NativeMessage

@external(erlang, "campy_wx_native", "panel")
pub fn panel(parent: Dynamic, id: Int) -> Dynamic

/// Show the four yellow grab strips around a selected widget (they never
/// overlap the widget, so nothing is hidden). Each strip remembers its
/// offset so press coordinates convert into the widget's space.
@external(erlang, "campy_wx_native", "grab_show")
pub fn grab_show(
  view_id: String,
  parent: Dynamic,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> Nil

/// Reposition the grab strips around a moved/resized widget.
@external(erlang, "campy_wx_native", "grab_move")
pub fn grab_move(view_id: String, x: Int, y: Int, w: Int, h: Int) -> Nil

/// Destroy a widget's grab strips.
@external(erlang, "campy_wx_native", "grab_hide")
pub fn grab_hide(view_id: String) -> Nil

/// Which widget a strip press belongs to, and the strip's offset into that
/// widget's space.
@external(erlang, "campy_wx_native", "grab_owner")
pub fn grab_owner(wx_id: Int) -> Result(#(String, Int, Int), Nil)

/// The ids of every widget with grab strips showing.
@external(erlang, "campy_wx_native", "grab_list")
pub fn grab_list() -> List(String)

/// A fresh wx id for chrome (grab strips, the form plate).
@external(erlang, "campy_wx_native", "grab_next_id")
pub fn grab_next_id() -> Int

/// Create or move the form plate: the form as a selectable white panel on
/// the canvas, kept below the controls.
@external(erlang, "campy_wx_native", "form_plate_set")
pub fn form_plate_set(
  view_id: String,
  parent: Dynamic,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> Nil

@external(erlang, "campy_wx_native", "form_plate_get")
pub fn form_plate_get(view_id: String) -> Result(Dynamic, Nil)

/// Destroy every form plate except the one for this form view id: switching
/// modules must not stack plates on the canvas.
@external(erlang, "campy_wx_native", "form_plate_retain")
pub fn form_plate_retain(view_id: String) -> Nil

@external(erlang, "campy_wx_native", "form_plate_rect")
pub fn form_plate_rect(view_id: String) -> Result(#(Int, Int, Int, Int), Nil)

/// Which form id a plate press belongs to.
@external(erlang, "campy_wx_native", "plate_owner")
pub fn plate_owner(wx_id: Int) -> Result(String, Nil)

/// The pointer position in a window's client coordinates: drags read the
/// true pointer so a moving widget cannot shift the coordinate base.
@external(erlang, "campy_wx_native", "pointer_in")
pub fn pointer_in(ref: Dynamic) -> #(Int, Int)

// Probe support: shell internals and synthetic event injection, so scripted
// tests drive the real message pump and the real IDE loop.
@external(erlang, "campy_wx_native", "null_ref")
pub fn null_ref() -> Dynamic

@external(erlang, "campy_wx_native", "view_wx_id")
pub fn view_wx_id(shell: a, view_id: String) -> Result(Int, Nil)

@external(erlang, "campy_wx_native", "view_ref")
pub fn view_ref(shell: a, view_id: String) -> Result(Dynamic, Nil)

@external(erlang, "campy_wx_native", "pointer_override")
pub fn pointer_override(x: Int, y: Int) -> Nil

@external(erlang, "campy_wx_native", "pointer_clear")
pub fn pointer_clear() -> Nil

@external(erlang, "campy_wx_native", "grab_strip_wx_id")
pub fn grab_strip_wx_id(view_id: String) -> Result(Int, Nil)

/// A grab strip's wx id and offset by index (0=top, 1=bottom, 2=left,
/// 3=right), for scripted strip presses.
@external(erlang, "campy_wx_native", "grab_strip_info")
pub fn grab_strip_info(
  view_id: String,
  index: Int,
) -> Result(#(Int, Int, Int), Nil)

@external(erlang, "campy_wx_native", "palette_tool")
pub fn palette_tool(kind: String) -> Result(Int, Nil)

@external(erlang, "campy_wx_native", "plate_wx_id")
pub fn plate_wx_id(view_id: String) -> Result(Int, Nil)

@external(erlang, "campy_wx_native", "enum_popup_list")
pub fn enum_popup_list() -> Result(Dynamic, Nil)

@external(erlang, "campy_wx_native", "enum_popup_wx_id")
pub fn enum_popup_wx_id() -> Result(Int, Nil)

/// Is the open dropdown anchored at the cell it belongs to?
@external(erlang, "campy_wx_native", "debug_str")
pub fn debug_str(term: a) -> String

@external(erlang, "campy_wx_native", "enum_popup_anchored")
pub fn enum_popup_anchored() -> Result(Bool, Nil)

/// Dev instrumentation (CAMPY_DUMP=1): print one line per registered widget.
@external(erlang, "campy_wx_native", "widget_report")
pub fn widget_report(shell: a) -> Nil

@external(erlang, "campy_wx_native", "enum_popup_select")
pub fn enum_popup_select(index: Int) -> Nil

@external(erlang, "campy_wx_native", "inspector_cell")
pub fn inspector_cell(shell: a, row: Int, col: Int) -> String

@external(erlang, "campy_wx_native", "child_count")
pub fn child_count(ref: Dynamic) -> Int

@external(erlang, "campy_wx_native", "toolbar_stats")
pub fn toolbar_stats(
  bar: Dynamic,
) -> #(#(Int, Int), #(Int, Int), #(Int, Int), #(Int, Int))

@external(erlang, "campy_wx_native", "inject_mouse")
pub fn inject_mouse(
  wx_id: Int,
  ref: Dynamic,
  kind: String,
  x: Int,
  y: Int,
  control: Bool,
) -> Nil

@external(erlang, "campy_wx_native", "inject_command")
pub fn inject_command(wx_id: Int, kind: String, int: Int) -> Nil

@external(erlang, "campy_wx_native", "inject_grid_select")
pub fn inject_grid_select(ref: Dynamic, row: Int, col: Int) -> Nil

@external(erlang, "campy_wx_native", "inject_list_pick")
pub fn inject_list_pick(
  list_id: Int,
  list: Dynamic,
  text: String,
  index: Int,
) -> Nil

@external(erlang, "campy_wx_native", "inject_strip_press")
pub fn inject_strip_press(wx_id: Int, x: Int, y: Int) -> Nil

@external(erlang, "campy_wx_native", "inject_plate_press")
pub fn inject_plate_press(wx_id: Int, x: Int, y: Int) -> Nil

@external(erlang, "campy_wx_native", "inject_tool_press")
pub fn inject_tool_press(wx_id: Int) -> Nil

/// Capture a window's on-screen content into a PNG (probe diagnostics).
@external(erlang, "campy_wx_native", "snapshot")
pub fn snapshot(ref: Dynamic, path: String) -> Nil

@external(erlang, "campy_wx_native", "label")
pub fn label(parent: Dynamic, id: Int, text: String) -> Dynamic

@external(erlang, "campy_wx_native", "button")
pub fn button(parent: Dynamic, id: Int, text: String) -> Dynamic

@external(erlang, "campy_wx_native", "checkbox")
pub fn checkbox(parent: Dynamic, id: Int, text: String) -> Dynamic

@external(erlang, "campy_wx_native", "radio")
pub fn radio(parent: Dynamic, id: Int, text: String) -> Dynamic

@external(erlang, "campy_wx_native", "choice")
pub fn choice(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "listbox")
pub fn listbox(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "textctrl")
pub fn textctrl(parent: Dynamic, id: Int, value: String) -> Dynamic

@external(erlang, "campy_wx_native", "memo")
pub fn memo(parent: Dynamic, id: Int, value: String) -> Dynamic

@external(erlang, "campy_wx_native", "slider")
pub fn slider(
  parent: Dynamic,
  id: Int,
  value: Int,
  min: Int,
  max: Int,
) -> Dynamic

@external(erlang, "campy_wx_native", "gauge")
pub fn gauge(parent: Dynamic, id: Int, range: Int) -> Dynamic

@external(erlang, "campy_wx_native", "picture")
pub fn picture(parent: Dynamic, id: Int, path: String) -> Dynamic

@external(erlang, "campy_wx_native", "box_sizer")
pub fn box_sizer(vertical: Bool) -> Dynamic

@external(erlang, "campy_wx_native", "add")
pub fn add(
  sizer: Dynamic,
  child: Dynamic,
  border: Int,
  expand: Bool,
  proportion: Int,
) -> Nil

@external(erlang, "campy_wx_native", "insert")
pub fn insert(
  sizer: Dynamic,
  index: Int,
  child: Dynamic,
  border: Int,
  expand: Bool,
  proportion: Int,
) -> Nil

@external(erlang, "campy_wx_native", "detach")
pub fn detach(sizer: Dynamic, child: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "set_sizer")
pub fn set_sizer(window: Dynamic, sizer: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "freeze")
pub fn freeze(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "thaw")
pub fn thaw(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "layout")
pub fn layout(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "layout_sizer")
pub fn layout_sizer(window: Dynamic, sizer: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "move")
pub fn move(ref: Dynamic, x: Int, y: Int) -> Nil

@external(erlang, "campy_wx_native", "resize")
pub fn resize(ref: Dynamic, width: Int, height: Int) -> Nil

/// A widget's current on-screen rectangle #(x, y, w, h) in its parent's
/// coordinates.
@external(erlang, "campy_wx_native", "widget_rect")
pub fn widget_rect(ref: Dynamic) -> Result(#(Int, Int, Int, Int), Nil)

@external(erlang, "campy_wx_native", "set_min_size")
pub fn set_min_size(ref: Dynamic, width: Int, height: Int) -> Nil

/// A window's client area as #(Width, Height); the align docking pass
/// resolves free-layout children against this.
@external(erlang, "campy_wx_native", "client_size")
pub fn client_size(ref: Dynamic) -> #(Int, Int)

@external(erlang, "campy_wx_native", "set_label")
pub fn set_label(ref: Dynamic, text: String) -> Nil

@external(erlang, "campy_wx_native", "set_text")
pub fn set_text(ref: Dynamic, text: String) -> Nil

@external(erlang, "campy_wx_native", "set_int")
pub fn set_int(ref: Dynamic, kind: String, value: Int) -> Nil

@external(erlang, "campy_wx_native", "set_bool")
pub fn set_bool(ref: Dynamic, kind: String, value: Bool) -> Nil

@external(erlang, "campy_wx_native", "set_selection")
pub fn set_selection(ref: Dynamic, kind: String, index: Int) -> Nil

@external(erlang, "campy_wx_native", "set_items")
pub fn set_items(ref: Dynamic, kind: String, items: List(String)) -> Nil

@external(erlang, "campy_wx_native", "set_enabled")
pub fn set_enabled(ref: Dynamic, enabled: Bool) -> Nil

@external(erlang, "campy_wx_native", "set_visible")
pub fn set_visible(ref: Dynamic, visible: Bool) -> Nil

@external(erlang, "campy_wx_native", "refresh_window")
pub fn refresh(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "update_window")
pub fn update(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "set_background")
pub fn set_background(ref: Dynamic, r: Int, g: Int, b: Int) -> Nil

/// Background colour from a "#rrggbb" hex string (scheme-aware canvases).
@external(erlang, "campy_wx_native", "set_background_hex")
pub fn set_background_hex(ref: Dynamic, hex: String) -> Nil

@external(erlang, "campy_wx_native", "focus")
pub fn focus(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "focus_ignoring_children")
pub fn focus_ignoring_children(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "set_editable")
pub fn set_editable(ref: Dynamic, editable: Bool) -> Nil

@external(erlang, "campy_wx_native", "raise")
pub fn raise(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "destroy")
pub fn destroy(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "get_text")
pub fn get_text(ref: Dynamic) -> String

@external(erlang, "campy_wx_native", "get_int")
pub fn get_int(ref: Dynamic, kind: String) -> Int

@external(erlang, "campy_wx_native", "get_bool")
pub fn get_bool(ref: Dynamic, kind: String) -> Bool

@external(erlang, "campy_wx_native", "get_selection")
pub fn get_selection(ref: Dynamic, kind: String) -> Int

pub type GridCell {
  GridCell(row: Int, col: Int, text: String)
}

@external(erlang, "campy_wx_native", "menubar")
pub fn menubar() -> Dynamic

@external(erlang, "campy_wx_native", "menu")
pub fn menu() -> Dynamic

@external(erlang, "campy_wx_native", "menuitem")
pub fn menuitem(parent: Dynamic, id: Int, label: String) -> Dynamic

@external(erlang, "campy_wx_native", "append_menu")
pub fn append_menu(bar: Dynamic, menu: Dynamic, title: String) -> Nil

@external(erlang, "campy_wx_native", "set_menubar")
pub fn set_menubar(frame: Dynamic, bar: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "toolbar")
pub fn toolbar(frame: Dynamic) -> Dynamic

@external(erlang, "campy_wx_native", "tool")
pub fn tool(bar: Dynamic, id: Int, label: String) -> Dynamic

/// A toolbar tool; "run"/"stop" get drawn pictograms, others keep labels.
@external(erlang, "campy_wx_native", "tool")
pub fn tool_icon(bar: Dynamic, id: Int, label: String, icon: String) -> Dynamic

/// The widget palette: pictogram tools inside the toolbar (right of the
/// Run/Stop tools), one per catalog widget. Presses are routed back through
/// `palette_owner`.
@external(erlang, "campy_wx_native", "palette")
pub fn palette(bar: Dynamic, entries: List(#(String, String))) -> Dynamic

/// The widget kind a palette button press belongs to.
@external(erlang, "campy_wx_native", "palette_owner")
pub fn palette_owner(wx_id: Int) -> Result(String, Nil)

@external(erlang, "campy_wx_native", "tool_separator")
pub fn tool_separator(bar: Dynamic) -> Dynamic

@external(erlang, "campy_wx_native", "realize_toolbar")
pub fn realize_toolbar(bar: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "statusbar")
pub fn statusbar(frame: Dynamic) -> Dynamic

@external(erlang, "campy_wx_native", "set_status")
pub fn set_status(bar: Dynamic, text: String) -> Nil

@external(erlang, "campy_wx_native", "notebook")
pub fn notebook(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "page")
pub fn page(book: Dynamic, id: Int, title: String) -> Dynamic

@external(erlang, "campy_wx_native", "notebook_selection")
pub fn notebook_selection(book: Dynamic) -> Int

@external(erlang, "campy_wx_native", "select_page")
pub fn select_page(book: Dynamic, index: Int) -> Nil

@external(erlang, "campy_wx_native", "tree")
pub fn tree(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "tree_set")
pub fn tree_set(tree: Dynamic, items: List(TreeItem)) -> Nil

@external(erlang, "campy_wx_native", "tree_selected_key")
pub fn tree_selected_key(tree: Dynamic) -> String

@external(erlang, "campy_wx_native", "grid")
pub fn grid(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "grid_set")
pub fn grid_set(grid: Dynamic, rows: List(List(String))) -> Nil

@external(erlang, "campy_wx_native", "grid_configure")
pub fn grid_configure(
  grid: Dynamic,
  show_labels: Bool,
  show_lines: Bool,
  row_height: Int,
  label_width: Int,
) -> Nil

@external(erlang, "campy_wx_native", "grid_cell")
pub fn grid_cell(grid: Dynamic) -> GridCell

@external(erlang, "campy_wx_native", "grid_number_cell")
pub fn grid_number_cell(grid: Dynamic, row: Int, col: Int, min: Int) -> Nil

@external(erlang, "campy_wx_native", "grid_text_cell")
pub fn grid_text_cell(grid: Dynamic, row: Int, col: Int) -> Nil

@external(erlang, "campy_wx_native", "grid_read_only")
pub fn grid_read_only(grid: Dynamic, row: Int, col: Int, read_only: Bool) -> Nil

/// A dropdown cell editor for enum properties (align, layout).
@external(erlang, "campy_wx_native", "grid_choice_cell")
pub fn grid_choice_cell(
  grid: Dynamic,
  row: Int,
  col: Int,
  options: List(String),
) -> Nil

@external(erlang, "campy_wx_native", "editor")
pub fn editor(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "editor_set")
pub fn editor_set(editor: Dynamic, text: String, read_only: Bool) -> Nil

@external(erlang, "campy_wx_native", "editor_configure")
pub fn editor_configure(editor: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "editor_autocomp")
pub fn editor_autocomp(
  editor: Dynamic,
  entered: Int,
  labels: List(String),
) -> Nil

@external(erlang, "campy_wx_native", "editor_word_at")
pub fn editor_word_at(editor: Dynamic) -> Result(#(Int, Int, String), Nil)

@external(erlang, "campy_wx_native", "editor_line_at")
pub fn editor_line_at(editor: Dynamic) -> #(Int, Int)

@external(erlang, "campy_wx_native", "editor_marker_add")
pub fn editor_marker_add(editor: Dynamic, line: Int, severity: Int) -> Nil

@external(erlang, "campy_wx_native", "editor_marker_clear")
pub fn editor_marker_clear(editor: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "editor_replace_line")
pub fn editor_replace_line(editor: Dynamic, line: Int, new_text: String) -> Nil

@external(erlang, "campy_wx_native", "editor_jump_list")
pub fn editor_jump_list(editor: Dynamic, entries: List(String)) -> Nil

@external(erlang, "campy_wx_native", "editor_jumped")
pub fn editor_jumped(editor: Dynamic) -> Result(String, Nil)

@external(erlang, "campy_wx_native", "editor_show_end")
pub fn editor_show_end(editor: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "editor_gleam")
pub fn editor_gleam(editor: Dynamic) -> Nil

/// Recolor an editor's Scintilla styles from a scheme palette
/// (["bg", "fg", "keyword", "comment", "string", "number", "punct", "type"]
/// as hex strings).
@external(erlang, "campy_wx_native", "editor_scheme")
pub fn editor_scheme(editor: Dynamic, palette: List(#(String, String))) -> Nil

/// Apply the chosen editor font family and size to every style the editors
/// use.
@external(erlang, "campy_wx_native", "editor_font")
pub fn editor_font(editor: Dynamic, face: String, size: Int) -> Nil

/// Explicit clipboard/undo commands on a Scintilla editor (copy, cut, paste,
/// undo, redo): this GTK build drops the default key bindings when a frame
/// accelerator table is installed.
@external(erlang, "campy_wx_native", "editor_clipboard")
pub fn editor_clipboard(editor: Dynamic, action: String) -> Nil

/// Token-color the editor's current buffer (container-lexer styling). Run
/// after every document replacement: `set_editor` resets the styling bytes.
@external(erlang, "campy_wx_native", "editor_style_gleam")
pub fn editor_style_gleam(editor: Dynamic, text: String) -> Nil

@external(erlang, "campy_wx_native", "editor_get_text")
pub fn editor_get_text(editor: Dynamic) -> String

/// The caret of a text editor as a 0-based #(Line, Column) pair.
pub type Caret {
  Caret(line: Int, column: Int)
}

@external(erlang, "campy_wx_native", "editor_caret")
pub fn editor_caret(editor: Dynamic) -> Caret

@external(erlang, "campy_wx_native", "editor_goto")
pub fn editor_goto(editor: Dynamic, line: Int, column: Int) -> Nil

/// Language-server diagnostics for an editor: squiggle underlines under the
/// offending lines plus margin markers. Rows are #(StartLine, EndLine,
/// Message, Severity) with 0-based lines and LSP severities (1 error,
/// 2 warning, 3 info).
@external(erlang, "campy_wx_native", "editor_diagnostics")
pub fn editor_diagnostics(
  editor: Dynamic,
  rows: List(#(Int, Int, String, Int)),
) -> Nil

@external(erlang, "campy_wx_native", "editor_autocomplete")
pub fn editor_autocomplete(editor: Dynamic, labels: List(String)) -> Nil

@external(erlang, "campy_wx_native", "open_dialog")
pub fn open_dialog(frame: Dynamic, wildcard: String) -> String

@external(erlang, "campy_wx_native", "save_dialog")
pub fn save_dialog(frame: Dynamic, wildcard: String, default: String) -> String

@external(erlang, "campy_wx_native", "show_message")
pub fn show_message(frame: Dynamic, title: String, message: String) -> Nil

/// Modal Settings → Editor… dialog. Returns the chosen indexes into the
/// caller's font/size/scheme lists, or `Error(Nil)` on Cancel.
@external(erlang, "campy_wx_native", "settings_dialog")
pub fn settings_dialog(
  frame: Dynamic,
  fonts: List(String),
  sizes: List(String),
  schemes: List(String),
  font_index: Int,
  size_index: Int,
  scheme_index: Int,
) -> Result(#(Int, Int, Int), Nil)

/// Modal Settings → Agent… dialog. Returns the checkbox state and the port
/// text, or `Error(Nil)` on Cancel.
@external(erlang, "campy_wx_native", "agent_dialog")
pub fn agent_dialog(
  frame: Dynamic,
  enabled: Bool,
  port: String,
  status: String,
  endpoint: String,
) -> Result(#(Bool, String), Nil)

@external(erlang, "campy_wx_native", "set_tooltip")
pub fn set_tooltip(ref: Dynamic, text: String) -> Nil

@external(erlang, "campy_wx_native", "set_shortcuts")
pub fn set_shortcuts(frame: Dynamic, editing: Bool) -> Nil

@external(erlang, "campy_wx_native", "apply_shortcuts")
pub fn apply_shortcuts(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "canvas")
pub fn canvas(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "paint_canvas")
pub fn paint_canvas(
  ref: Dynamic,
  width: Int,
  height: Int,
  grid: Int,
  marquee: Option(#(Int, Int, Int, Int)),
  bg: String,
  grid_color: String,
) -> Nil

@external(erlang, "campy_wx_native", "connect_design")
pub fn connect_design(ref: Dynamic, kind: String) -> Nil

@external(erlang, "campy_wx_native", "handles_create")
pub fn handles_create(parent: Dynamic, base: Int) -> List(Dynamic)

@external(erlang, "campy_wx_native", "move_outline")
pub fn move_outline(
  canvas: Dynamic,
  refs: List(Dynamic),
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> Nil

@external(erlang, "campy_wx_native", "handle_place")
pub fn handle_place(
  canvas: Dynamic,
  ref: Dynamic,
  x: Int,
  y: Int,
  width: Int,
  height: Int,
) -> Nil

@external(erlang, "campy_wx_native", "handle_show")
pub fn handle_show(ref: Dynamic, visible: Bool) -> Nil

@external(erlang, "campy_wx_native", "handle_raise")
pub fn handle_raise(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "capture")
pub fn capture(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "release")
pub fn release(ref: Dynamic) -> Nil

@external(erlang, "campy_wx_native", "release_capture")
pub fn release_capture() -> Nil

@external(erlang, "campy_wx_native", "set_cursor")
pub fn set_cursor(ref: Dynamic, role: Int) -> Nil

@external(erlang, "campy_wx_native", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "campy_wx_native", "getenv")
pub fn getenv(name: String) -> String
