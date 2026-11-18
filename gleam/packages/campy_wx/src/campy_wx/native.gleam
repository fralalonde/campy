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
  StcJump(wx_id: Int)
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

@external(erlang, "campy_wx_native", "set_min_size")
pub fn set_min_size(ref: Dynamic, width: Int, height: Int) -> Nil

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
  selection: Option(#(Int, Int, Int, Int)),
  marquee: Option(#(Int, Int, Int, Int)),
  single: Bool,
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
