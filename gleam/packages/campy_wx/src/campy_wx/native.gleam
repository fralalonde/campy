//// Thin typed wrappers over the Erlang wx adapter (`campy_wx_native.erl`).
////
//// Widget handles are opaque Erlang terms (`wx_ref` records). They are typed
//// as `Dynamic` here and never inspected; the adapter is the only place that
//// knows wx atoms, options, and record shapes.

import campy_wx/plan.{type TreeItem}
import gleam/dynamic.{type Dynamic}

pub type NativeMessage {
  WxEvent(wx_id: Int, event_type: String)
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

@external(erlang, "campy_wx_native", "focus")
pub fn focus(ref: Dynamic) -> Nil

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

@external(erlang, "campy_wx_native", "grid_cell")
pub fn grid_cell(grid: Dynamic) -> GridCell

@external(erlang, "campy_wx_native", "editor")
pub fn editor(parent: Dynamic, id: Int) -> Dynamic

@external(erlang, "campy_wx_native", "editor_set")
pub fn editor_set(editor: Dynamic, text: String, read_only: Bool) -> Nil

@external(erlang, "campy_wx_native", "open_dialog")
pub fn open_dialog(frame: Dynamic, wildcard: String) -> String

@external(erlang, "campy_wx_native", "save_dialog")
pub fn save_dialog(frame: Dynamic, wildcard: String, default: String) -> String

@external(erlang, "campy_wx_native", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "campy_wx_native", "getenv")
pub fn getenv(name: String) -> String
