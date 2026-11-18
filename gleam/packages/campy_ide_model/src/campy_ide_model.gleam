//// Display-free IDE state.
////
//// The wx shell (`campy_ide_wx`, T1.4) owns no document logic: it renders this
//// state and sends commands here. Everything in this module is pure, so the
//// IDE's behaviour is testable without a display.
////
//// M2 adds designer edits: placement from the palette, reparenting, z-order,
//// clipboard, duplication, deletion, and geometry commits. Every edit ends in
//// `commit`, so the shell only has to re-render the result and undo works for
//// each user gesture.

import campy_app
import campy_appgen
import campy_catalog
import campy_design
import campy_lsp
import campy_peer.{type Peer}
import campy_project.{type Module, type Project}
import campy_view.{type Node, type Value, VText}
import campy_view/codec.{type Json, JBool, JInt, JObject, JString}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const console_limit = 500

pub const undo_limit = 100

/// Font family choices offered by Settings → Editor… (same list as the
/// Slint-era settings dialog).
pub const fonts = [
  "monospace", "DejaVu Sans Mono", "Liberation Mono", "Courier New",
  "Noto Sans Mono",
]

/// Font size choices offered by Settings → Editor…, in points.
pub const sizes = [11, 12, 13, 14, 16, 18, 20]

/// The default MCP agent port (the Slint version's default).
pub const default_mcp_port = 7817

/// Editor color scheme. The scheme recolors the code/source/console editors
/// and the design canvas; the native shell chrome keeps the GTK colors.
pub type Scheme {
  Dark
  Light
  Solarized
}

/// Everything Settings → Editor…/Agent… controls. Not a document field: it
/// lives outside undo/redo and persists to the user's config directory.
pub type Settings {
  Settings(
    /// Editor font family, one of `fonts`.
    font: String,
    /// Editor font size in points, one of `sizes`.
    font_size: Int,
    scheme: Scheme,
    /// The MCP agent server is disabled (and, in this build, not available);
    /// the option is kept for parity with the Slint version.
    mcp_enabled: Bool,
    mcp_port: Int,
  )
}

pub type State {
  State(
    project: Project,
    open_tabs: List(String),
    active: Option(String),
    selection: List(String),
    console: List(String),
    undo: List(Project),
    redo: List(Project),
    status: String,
    /// The explicitly chosen notebook page.
    page: Page,
    code_view: Bool,
    /// The generated-source page. At most one of `code_view` and
    /// `source_view` is true; both false means the design canvas (Form).
    source_view: Bool,
    /// The Debug page, like nodes_view an explicit page choice.
    debug_view: Bool,
    /// The Nodes page. It overrides the Form/Code/Source flags while set;
    /// Run (an attached app) still wins because page_index checks running
    /// first.
    nodes_view: Bool,
    /// Copied subtrees with their canvas-absolute rectangles, in selection
    /// order. Copies are cloned again on paste so pasting twice does not
    /// create duplicate ids; the rect keeps sizer/aligned children placeable.
    clipboard: List(ClipboardItem),
    /// Palette kind armed for placement, if any. UI intent, not a document
    /// field; placing a control disarms it.
    armed: Option(String),
    /// The running app: its dispatch subject and the module slug. Owned by
    /// the shell; the model only records and routes.
    running: Option(campy_app.Running),
    /// The latest published view document from the running app, with the
    /// generation it was derived from.
    live_view: Option(campy_view.Document),
    /// Known peer nodes, started through the node manager.
    peers: List(Peer),
    /// The name typed into the Nodes page's peer-name field.
    nodes_name: String,
    /// The send/receive tracer for the attached app, when tracing is on.
    /// It lives on the app's node; the pid is carried as an opaque term.
    tracer: Option(Dynamic),
    /// The peer the app tree selection points at, by node name.
    selected_peer: Option(String),
    /// The Gleam language server the editor talks to. The IDE owns the
    /// process lifecycle; this records the client, the document the server
    /// has open, the text last pushed to it, and the latest diagnostics so
    /// the editor can re-paint them after a document replacement.
    lsp: Lsp,
    /// Editor appearance and agent options (Settings menu). UI state, not a
    /// document edit: no undo entry, persisted to the user's config dir.
    settings: Settings,
  )
}

/// Language-server runtime state for the Code editor. `text` mirrors what the
/// editor buffer contained at the last push; `diags` are the server's latest
/// findings for `file` as 0-based #(StartLine, EndLine, Message, Severity)
/// rows.
pub type Lsp {
  Lsp(
    client: Option(campy_lsp.Client),
    file: Option(String),
    text: String,
    version: Int,
    diags: List(Diag),
  )
}

/// One diagnostic row, 0-based: the line range, the message, and the LSP
/// severity (1 error, 2 warning, 3 info).
pub type Diag {
  Diag(line: Int, end_line: Int, text: String, severity: Int)
}

/// An LSP with no client yet; nothing is open and no diagnostics are known.
pub fn no_lsp() -> Lsp {
  Lsp(client: None, file: None, text: "", version: 0, diags: [])
}

// ---------------------------------------------------------------------------
// Settings (Settings → Editor…, Settings → Agent…)
// ---------------------------------------------------------------------------

/// The Slint version's defaults: monospace 13 on Dark, agent disabled on
/// port 7817.
pub fn default_settings() -> Settings {
  Settings(
    font: "monospace",
    font_size: 13,
    scheme: Dark,
    mcp_enabled: False,
    mcp_port: default_mcp_port,
  )
}

/// Replace the settings wholesale. Settings are UI state, not a document
/// edit, so this does not touch undo/redo.
pub fn apply_settings(state: State, settings: Settings) -> State {
  State(..state, settings: normalize(settings))
}

/// Force a settings value back into the offered choices: unknown fonts and
/// sizes fall back to the defaults, and the port keeps its bounds.
pub fn normalize(settings: Settings) -> Settings {
  let font = case list.contains(fonts, settings.font) {
    True -> settings.font
    False -> "monospace"
  }
  let font_size = case list.contains(sizes, settings.font_size) {
    True -> settings.font_size
    False -> 13
  }
  let mcp_port = case settings.mcp_port >= 1024 && settings.mcp_port <= 65_535 {
    True -> settings.mcp_port
    False -> default_mcp_port
  }
  Settings(..settings, font: font, font_size: font_size, mcp_port: mcp_port)
}

pub fn scheme_name(scheme: Scheme) -> String {
  case scheme {
    Dark -> "Dark"
    Light -> "Light"
    Solarized -> "Solarized"
  }
}

pub fn scheme_from_name(name: String) -> Scheme {
  case name {
    "Light" -> Light
    "Solarized" -> Solarized
    _ -> Dark
  }
}

/// The scheme combo's entries, in display order.
pub fn scheme_names() -> List(String) {
  ["Dark", "Light", "Solarized"]
}

/// The scheme combo index for the current scheme.
pub fn scheme_index(scheme: Scheme) -> Int {
  index_of(scheme_names(), scheme_name(scheme))
}

/// The font combo index for the current settings (0 when unknown).
pub fn font_index(settings: Settings) -> Int {
  case list.contains(fonts, settings.font) {
    True -> index_of(fonts, settings.font)
    False -> 0
  }
}

/// The size combo index for the current settings (the default's index when
/// unknown).
pub fn size_index(settings: Settings) -> Int {
  case list.contains(sizes, settings.font_size) {
    True -> index_of(sizes, settings.font_size)
    False -> index_of(sizes, 13)
  }
}

fn index_of(items: List(a), item: a) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case first == item {
        True -> 0
        False -> 1 + index_of(rest, item)
      }
  }
}

/// Editor and canvas colors for a scheme, as hex strings (the Slint
/// version's palettes). Keys: "canvas" and "grid" for the design canvas;
/// "bg" and "fg" for an editor's default style; then the Gleam token styles
/// "keyword", "comment", "string", "number", "punct", "type".
pub fn scheme_palette(scheme: Scheme) -> List(#(String, String)) {
  case scheme {
    Light -> [
      #("canvas", "#e6e6e6"),
      #("grid", "#c6c6c6"),
      #("bg", "#ffffff"),
      #("fg", "#202020"),
      #("keyword", "#a626a4"),
      #("comment", "#6a737d"),
      #("string", "#50a14f"),
      #("number", "#986801"),
      #("punct", "#0184bc"),
      #("type", "#c18401"),
    ]
    Solarized -> [
      #("canvas", "#001f27"),
      #("grid", "#0a3a46"),
      #("bg", "#002b36"),
      #("fg", "#93a1a1"),
      #("keyword", "#859900"),
      #("comment", "#586e75"),
      #("string", "#2aa198"),
      #("number", "#d33682"),
      #("punct", "#6c71c4"),
      #("type", "#b58900"),
    ]
    Dark -> [
      #("canvas", "#14161a"),
      #("grid", "#2f3540"),
      #("bg", "#282c34"),
      #("fg", "#abb2bf"),
      #("keyword", "#c678dd"),
      #("comment", "#7f848e"),
      #("string", "#98c379"),
      #("number", "#d19a66"),
      #("punct", "#56b6c2"),
      #("type", "#e5c07b"),
    ]
  }
}

/// The settings document, written to the user's config directory.
pub fn settings_to_json(settings: Settings) -> Json {
  JObject([
    #("schema", JInt(1)),
    #("font", JString(settings.font)),
    #("font_size", JInt(settings.font_size)),
    #("scheme", JString(scheme_name(settings.scheme))),
    #("mcp_enabled", JBool(settings.mcp_enabled)),
    #("mcp_port", JInt(settings.mcp_port)),
  ])
}

/// Read settings back from a stored document; unknown or invalid fields fall
/// back to the defaults, so a newer or damaged file cannot break the IDE.
pub fn settings_from_json(json: Json) -> Result(Settings, String) {
  case json {
    JObject(fields) -> {
      let font = case string_field(fields, "font") {
        Ok(font) -> font
        Error(Nil) -> "monospace"
      }
      let font_size = case int_field(fields, "font_size") {
        Ok(size) -> size
        Error(Nil) -> 13
      }
      let scheme = case string_field(fields, "scheme") {
        Ok(name) -> scheme_from_name(name)
        Error(Nil) -> Dark
      }
      let mcp_enabled = case bool_field(fields, "mcp_enabled") {
        Ok(enabled) -> enabled
        Error(Nil) -> False
      }
      let mcp_port = case int_field(fields, "mcp_port") {
        Ok(port) -> port
        Error(Nil) -> default_mcp_port
      }

      Ok(
        normalize(Settings(
          font: font,
          font_size: font_size,
          scheme: scheme,
          mcp_enabled: mcp_enabled,
          mcp_port: mcp_port,
        )),
      )
    }
    _ -> Error("$: expected an object")
  }
}

fn string_field(
  fields: List(#(String, Json)),
  name: String,
) -> Result(String, Nil) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, JString(value))) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn int_field(fields: List(#(String, Json)), name: String) -> Result(Int, Nil) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, JInt(value))) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn bool_field(
  fields: List(#(String, Json)),
  name: String,
) -> Result(Bool, Nil) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, JBool(value))) -> Ok(value)
    _ -> Error(Nil)
  }
}

pub type ClipboardItem {
  ClipboardItem(node: Node, rect: campy_design.Rect)
}

/// The notebook page the user has chosen. Tab clicks and shortcuts set it
/// explicitly, so the designer can always be reached while an app runs.
/// The running app shows in its own top-level window, not a notebook page.
pub type Page {
  DesignPage
  CodePage
  SourcePage
  NodesPage
  DebugPage
}

pub type Command {
  OpenModule(String)
  CloseModule(String)
  SelectControls(List(String))
  Commit(Project)
  Undo
  Redo
  Log(String)
  SetStatus(String)
  ToggleCodeView
  ToggleSourceView
  ShowForm
  ShowCode
  ShowSource
  ClearConsole
  Arm(String)
  Disarm
  PlaceWidget(kind: String, x: Int, y: Int, w: Int, h: Int)
  CopySelection
  CutSelection
  Paste
  DuplicateSelection
  DeleteSelection
  BringToFront
  SendToBack
  CommitGeometry(
    items: List(#(String, campy_design.Rect)),
    reparent: Option(#(String, String)),
  )
  SetControlRect(id: String, rect: campy_design.Rect)
  SetControlProp(id: String, name: String, value: Value)
  RunStarted(campy_app.Running)
  RunView(campy_view.Document, Int)
  RunReport(String)
  RunCodeUpdated(Int)
  RunStopped
  PeerStarted(Peer)
  PeerStopped(String)
  PeerSelected(String)
  PeerGone(String)
  SetNodesName(String)
  ShowNodes
  ShowDebug
  TracingStarted(Dynamic)
  TracingStopped
  SetHandlers(String)
  /// Live typing in the Code editor: adopt the buffer as the module's
  /// handler source WITHOUT an undo entry or a status change — text undo
  /// belongs to Scintilla, and the model must track the buffer so refresh
  /// never reverts it.
  TypedHandlers(String)
  OpenHandler(control_id: String, event: String)
  /// The language-server client the editor will use (spawned once per run).
  LspStarted(campy_lsp.Client)
  /// The language server went away (crashed or was stopped).
  LspDown(String)
  /// The editor pushed its current text to the server: file, version, text.
  LspPushed(String, Int, String)
  /// The server published diagnostics for a file.
  LspDiagnostics(String, List(Diag))
  /// Replace all settings at once (one dialog OK). No undo entry.
  ApplySettings(Settings)
}

pub fn new(project: Project) -> State {
  let state =
    State(
      project: project,
      open_tabs: [],
      active: None,
      selection: [],
      console: [],
      undo: [],
      redo: [],
      status: "",
      page: DesignPage,
      code_view: False,
      source_view: False,
      nodes_view: False,
      debug_view: False,
      clipboard: [],
      armed: None,
      running: None,
      live_view: None,
      peers: [],
      nodes_name: "node1",
      tracer: None,
      selected_peer: None,
      lsp: no_lsp(),
      settings: default_settings(),
    )

  case project.modules {
    [] -> state
    [first, ..] ->
      case open_module(state, first.slug) {
        Ok(state) -> state
        Error(_) -> state
      }
  }
}

pub fn open_module(state: State, slug: String) -> Result(State, String) {
  use _module <- result.try(campy_project.module(state.project, slug))

  let open_tabs = case list.contains(state.open_tabs, slug) {
    True -> state.open_tabs
    False -> list.append(state.open_tabs, [slug])
  }

  Ok(
    State(
      ..state,
      open_tabs: open_tabs,
      active: Some(slug),
      selection: [],
      armed: None,
    ),
  )
}

pub fn close_module(state: State, slug: String) -> State {
  let open_tabs = list.filter(state.open_tabs, fn(tab) { tab != slug })

  let active = case state.active {
    Some(current) if current == slug ->
      case open_tabs {
        [next, ..] -> Some(next)
        [] -> None
      }
    _ -> state.active
  }

  State(
    ..state,
    open_tabs: open_tabs,
    active: active,
    selection: [],
    armed: None,
  )
}

pub fn select_controls(state: State, ids: List(String)) -> State {
  State(..state, selection: ids)
}

/// Replace the project with a new snapshot, recording undo. An unchanged
/// project is not recorded, so repeated no-op edits do not fill the history.
pub fn commit(state: State, project: Project) -> State {
  case project == state.project {
    True -> state
    False ->
      State(
        ..state,
        project: project,
        undo: list.take([state.project, ..state.undo], undo_limit),
        redo: [],
      )
  }
}

/// Selection ids that still exist in the restored project's active module.
/// A failed lookup (no active module, or the module is gone) clears it.
fn retained_selection(state: State, project: Project) -> List(String) {
  case state.active {
    None -> []
    Some(slug) ->
      case campy_project.module(project, slug) {
        Ok(module) -> {
          let ids = campy_view.ids(module.form.view)
          list.filter(state.selection, fn(id) { list.contains(ids, id) })
        }
        Error(_) -> []
      }
  }
}

pub fn undo(state: State) -> State {
  case state.undo {
    [] -> state
    [previous, ..rest] ->
      State(
        ..state,
        project: previous,
        selection: retained_selection(state, previous),
        undo: rest,
        redo: list.take([state.project, ..state.redo], undo_limit),
      )
  }
}

pub fn redo(state: State) -> State {
  case state.redo {
    [] -> state
    [next, ..rest] ->
      State(
        ..state,
        project: next,
        selection: retained_selection(state, next),
        redo: rest,
        undo: list.take([state.project, ..state.undo], undo_limit),
      )
  }
}

pub fn log(state: State, line: String) -> State {
  State(..state, console: list.take([line, ..state.console], console_limit))
}

pub fn set_status(state: State, text: String) -> State {
  State(..state, status: text)
}

/// Exactly one editor page is active at a time: Form (neither flag), Code, or
/// Source. Toggling the visible page returns to Form.
pub fn toggle_code_view(state: State) -> State {
  case state.code_view {
    True -> show_form(state)
    False -> show_code(state)
  }
}

pub fn toggle_source_view(state: State) -> State {
  case state.source_view {
    True -> show_form(state)
    False -> show_source(state)
  }
}

pub fn show_form_page(state: State) -> State {
  show_form(state)
}

pub fn show_code_page(state: State) -> State {
  show_code(state)
}

pub fn show_source_page(state: State) -> State {
  show_source(state)
}

/// Page selection is an explicit user choice: picking Form/Code/Source (by
/// tab or shortcut) must also leave the Nodes/Debug pages.
fn clear_special_pages(state: State) -> State {
  State(..state, nodes_view: False, debug_view: False)
}

/// The Run tab (or attaching an app) shows the Run page.
/// Clear the console buffer. This is UI state, not a document edit, so it does
/// not create an undo entry.
pub fn clear_console(state: State) -> State {
  State(..state, console: [])
}

fn show_form(state: State) -> State {
  clear_special_pages(
    State(..state, page: DesignPage, code_view: False, source_view: False),
  )
}

fn show_code(state: State) -> State {
  clear_special_pages(
    State(..state, page: CodePage, code_view: True, source_view: False),
  )
}

fn show_source(state: State) -> State {
  clear_special_pages(
    State(..state, page: SourcePage, code_view: False, source_view: True),
  )
}

pub fn arm(state: State, kind: String) -> State {
  case campy_catalog.find(kind) {
    Ok(widget) ->
      State(..state, armed: Some(kind))
      |> set_status("Place " <> widget.label <> ": click or drag on the canvas")
    Error(error) -> set_status(state, error)
  }
}

pub fn disarm(state: State) -> State {
  State(..state, armed: None)
}

pub fn active_module(state: State) -> Result(Module, String) {
  case state.active {
    None -> Error("no active module")
    Some(slug) -> campy_project.module(state.project, slug)
  }
}

/// Replace the active module's form with `view`, recording one undo entry.
pub fn commit_view(state: State, module: Module, view: Node) -> State {
  let document =
    campy_view.Document(
      schema: module.form.schema,
      view: view,
      extra: module.form.extra,
    )

  let updated =
    campy_project.Module(
      slug: module.slug,
      form: document,
      handlers: module.handlers,
    )

  let modules =
    list.map(state.project.modules, fn(candidate) {
      case candidate.slug == module.slug {
        True -> updated
        False -> candidate
      }
    })

  commit(
    state,
    campy_project.Project(
      title: state.project.title,
      modules: modules,
      extra: state.project.extra,
    ),
  )
}

/// Place a catalog widget with its top-left at canvas coordinates `x, y`.
/// The drop adopts the deepest container under the point; the document is
/// frozen first so an existing column/row layout cannot drag the control back
/// into a stack.
pub fn place_widget(
  state: State,
  kind: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let root = campy_design.freeze(module.form.view)
      let layout = campy_design.resolve(root)
      let #(parent_id, origin_x, origin_y) = drop_target(root, layout, x, y)
      let id = fresh_id(campy_view.ids(root), kind)
      let width = case w > 0 {
        True -> w
        False -> campy_catalog.default_w(kind)
      }
      let height = case h > 0 {
        True -> h
        False -> campy_catalog.default_h(kind)
      }

      let made =
        campy_catalog.make_at(
          kind,
          id,
          int.max(0, x - origin_x),
          int.max(0, y - origin_y),
          width,
          height,
        )

      case made {
        Error(error) -> set_status(state, error)
        Ok(node) ->
          case
            campy_design.insert_child(
              root,
              parent_id,
              campy_design.child_count(root, parent_id),
              node,
            )
          {
            Error(error) -> set_status(state, error)
            Ok(view) ->
              state
              |> commit_view(module, view)
              |> select_controls([id])
              |> disarm()
              |> set_status("Added " <> campy_catalog.label_of(kind))
          }
      }
    }
  }
}

fn drop_target(
  root: Node,
  layout: campy_design.Layout,
  x: Int,
  y: Int,
) -> #(String, Int, Int) {
  case campy_design.container_for_drop(root, layout, x, y, None) {
    Some(placed) -> #(placed.id, placed.rect.x, placed.rect.y)
    None ->
      case campy_design.placed(layout, layout.root) {
        Some(placed) -> #(placed.id, placed.rect.x, placed.rect.y)
        None -> #(layout.root, 0, 0)
      }
  }
}

/// Copy the selected top-level subtrees into the clipboard.
pub fn copy_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let items = clipboard_items(module.form.view, state.selection)
      case items {
        [] -> set_status(state, "Nothing selected")
        _ ->
          State(..state, clipboard: items)
          |> set_status("Copied " <> int.to_string(list.length(items)))
      }
    }
  }
}

/// Copy the selection, then delete it. The clipboard survives the deletion, so
/// Cut followed by Paste works like a move.
pub fn cut_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let items = clipboard_items(module.form.view, state.selection)
      case items {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let count = int.to_string(list.length(items))
          State(..state, clipboard: items)
          |> delete_selection()
          |> set_status("Cut " <> count)
        }
      }
    }
  }
}

/// Remove the selected top-level subtrees. One undo entry covers the gesture.
pub fn delete_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)
      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let view =
            list.fold(nodes, module.form.view, fn(view, node) {
              case campy_design.remove_node(view, node.id) {
                Ok(#(updated, _removed)) -> updated
                Error(_) -> view
              }
            })

          state
          |> commit_view(module, view)
          |> select_controls([])
          |> set_status("Deleted " <> int.to_string(list.length(nodes)))
        }
      }
    }
  }
}

/// Paste clipboard subtrees with fresh ids. A selected container receives the
/// children; otherwise they become siblings after the selection, or top-level
/// children when nothing is selected.
pub fn paste(state: State) -> State {
  case state.clipboard {
    [] -> set_status(state, "Clipboard is empty")
    clipboard ->
      case active_module(state) {
        Error(error) -> set_status(state, error)
        Ok(module) -> {
          let root = campy_design.freeze(module.form.view)
          let #(parent_id, start) = paste_target(root, state.selection)
          let layout = campy_design.resolve(root)
          let #(ox, oy, ow, oh) = parent_frame(layout, parent_id)

          let #(view, ids, _existing, _next) =
            list.fold(
              clipboard,
              #(root, [], campy_view.ids(root), start),
              fn(acc, original) {
                let #(view, ids, existing, next) = acc
                let #(clone, existing) = clone_tree(original.node, existing)
                let clone =
                  campy_design.set_rect(
                    clone,
                    clone.id,
                    paste_rect(original.rect, ox, oy, ow, oh),
                  )
                let index =
                  int.min(next, campy_design.child_count(view, parent_id))

                case campy_design.insert_child(view, parent_id, index, clone) {
                  Ok(view) -> #(
                    view,
                    list.append(ids, [clone.id]),
                    existing,
                    next + 1,
                  )
                  Error(_) -> #(view, ids, existing, next)
                }
              },
            )

          state
          |> commit_view(module, view)
          |> select_controls(ids)
          |> set_status("Pasted " <> int.to_string(list.length(ids)))
        }
      }
  }
}

fn paste_target(root: Node, selection: List(String)) -> #(String, Int) {
  case selection {
    [id] ->
      case campy_design.find_node(root, id) {
        Some(node) ->
          case campy_catalog.accepts_children(node.kind) {
            True -> #(id, campy_design.child_count(root, id))
            False ->
              case campy_design.parent_of(root, id) {
                Some(parent) ->
                  case campy_design.index_of(root, parent, id) {
                    Ok(index) -> #(parent, index + 1)
                    Error(_) -> root_target(root)
                  }
                None -> root_target(root)
              }
          }
        None -> root_target(root)
      }
    _ -> root_target(root)
  }
}

fn root_target(root: Node) -> #(String, Int) {
  #(root.id, campy_design.child_count(root, root.id))
}

/// Duplicate the selection in place, offset a little so the copy is visible,
/// and select the copies.
pub fn duplicate_selection(state: State) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let root = campy_design.freeze(module.form.view)
      let layout = campy_design.resolve(root)
      let nodes = selected_top(root, state.selection)

      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          let #(view, ids, _) =
            list.fold(
              nodes,
              #(root, [], campy_view.ids(root)),
              fn(acc, original) {
                let #(view, ids, existing) = acc
                let #(clone, existing) = clone_tree(original, existing)

                let #(parent, index) = case
                  campy_design.parent_of(view, original.id)
                {
                  Some(parent) ->
                    case campy_design.index_of(view, parent, original.id) {
                      Ok(index) -> #(parent, index + 1)
                      Error(_) -> root_target(view)
                    }
                  None -> root_target(view)
                }

                let source = case campy_design.placed(layout, original.id) {
                  Some(placed) -> placed.rect
                  None ->
                    campy_design.Rect(
                      0,
                      0,
                      campy_design.default_w(original.kind),
                      campy_design.default_h(original.kind),
                    )
                }
                let #(ox, oy, ow, oh) = parent_frame(layout, parent)
                let clone =
                  campy_design.set_rect(
                    clone,
                    clone.id,
                    paste_rect(source, ox, oy, ow, oh),
                  )

                case campy_design.insert_child(view, parent, index, clone) {
                  Ok(view) -> #(view, list.append(ids, [clone.id]), existing)
                  Error(_) -> #(view, ids, existing)
                }
              },
            )

          state
          |> commit_view(module, view)
          |> select_controls(ids)
          |> set_status("Duplicated " <> int.to_string(list.length(ids)))
        }
      }
    }
  }
}

pub fn bring_to_front(state: State) -> State {
  reorder_selection(state, campy_design.bring_to_front)
}

pub fn send_to_back(state: State) -> State {
  reorder_selection(state, campy_design.send_to_back)
}

fn reorder_selection(
  state: State,
  operation: fn(Node, String) -> Result(Node, String),
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let nodes = selected_top(module.form.view, state.selection)

      case nodes {
        [] -> set_status(state, "Nothing selected")
        _ -> {
          // Dry-run the reorder so an already-front/back control is a true
          // no-op: no freeze, no undo entry, no rewritten props.
          let dry =
            list.fold(nodes, module.form.view, fn(view, node) {
              case operation(view, node.id) {
                Ok(updated) -> updated
                Error(_) -> view
              }
            })

          case dry == module.form.view {
            True -> state
            False -> {
              // Only sizer children need materialized geometry; reordering in
              // a free parent restacks without touching unrelated containers.
              let root = case
                list.any(nodes, fn(node) {
                  parent_uses_sizer(module.form.view, node.id)
                })
              {
                True -> campy_design.freeze(module.form.view)
                False -> module.form.view
              }

              let view =
                list.fold(nodes, root, fn(view, node) {
                  case operation(view, node.id) {
                    Ok(updated) -> updated
                    Error(_) -> view
                  }
                })

              state
              |> commit_view(module, view)
              |> set_status("Reordered " <> int.to_string(list.length(nodes)))
            }
          }
        }
      }
    }
  }
}

fn parent_uses_sizer(root: Node, id: String) -> Bool {
  case campy_design.parent_of(root, id) {
    Some(parent_id) ->
      case campy_design.find_node(root, parent_id) {
        Some(parent) ->
          case campy_view.prop(parent, "layout") {
            Ok(VText(layout)) -> layout == "column" || layout == "row"
            _ -> False
          }
        None -> False
      }
    None -> False
  }
}

/// True when every committed rectangle already matches the resolved document.
/// A click on a handle without moving must not freeze a sizer form or create an
/// undo entry.
fn geometry_unchanged(
  state: State,
  items: List(#(String, campy_design.Rect)),
) -> Bool {
  case active_module(state) {
    Error(_) -> True
    Ok(module) -> {
      let layout = campy_design.resolve(module.form.view)
      list.all(items, fn(item) {
        let #(id, rect) = item
        case campy_design.placed(layout, id) {
          Some(placed) -> placed.rect == rect
          None -> False
        }
      })
    }
  }
}

/// Commit absolute rectangles for a finished drag. `reparent` carries
/// `#(control, new_container)` when a single move crossed a container edge;
/// the absolute rect is applied after the move, so the control stays exactly
/// where the pointer left it.
pub fn commit_geometry(
  state: State,
  items: List(#(String, campy_design.Rect)),
  reparent: Option(#(String, String)),
) -> State {
  let unchanged = case reparent {
    None -> geometry_unchanged(state, items)
    Some(_) -> False
  }

  case unchanged {
    True -> state
    False ->
      case active_module(state) {
        Error(error) -> set_status(state, error)
        Ok(module) -> {
          let frozen = campy_design.freeze(module.form.view)
          let message = case reparent {
            None -> "Moved " <> int.to_string(list.length(items))
            Some(#(id, parent)) -> "Moved " <> id <> " to " <> parent
          }

          case reparent {
            None -> {
              // Resolve once, then store parent-relative rectangles. If a parent
              // is also moving, use its previewed absolute origin; otherwise use
              // the pre-edit frame. A group move keeps relative positions stable
              // even when a container and a child are both in the selection.
              let layout = campy_design.resolve(frozen)
              let desired = dict.from_list(items)
              let view =
                list.fold(items, frozen, fn(view, item) {
                  let #(id, rect) = item
                  let #(ox, oy) = parent_origin_for(layout, desired, id)
                  campy_design.set_rect(
                    view,
                    id,
                    campy_design.Rect(
                      x: rect.x - ox,
                      y: rect.y - oy,
                      w: rect.w,
                      h: rect.h,
                    ),
                  )
                })

              commit_view(state, module, view) |> set_status(message)
            }
            Some(#(id, parent)) -> {
              let view = case campy_design.reparent(frozen, id, parent) {
                Ok(updated) -> updated
                Error(_) -> frozen
              }

              let view =
                list.fold(items, view, fn(view, item) {
                  let #(id, rect) = item
                  campy_design.set_absolute_rect(view, id, rect)
                })

              commit_view(state, module, view) |> set_status(message)
            }
          }
        }
      }
  }
}

/// Set one control's absolute rectangle, as typed into the inspector. This is
/// the same path as a finished drag, so sizer forms freeze first, sizes clamp
/// to `campy_design.min_size`, and an unchanged rectangle is a no-op.
pub fn set_control_rect(
  state: State,
  id: String,
  rect: campy_design.Rect,
) -> State {
  commit_geometry(state, [#(id, rect)], None)
}

/// Set a non-geometry property (text, checked, items, ...). Geometry belongs in
/// `SetControlRect`; this keeps clamping and alignment rules in one place.
pub fn set_control_prop(
  state: State,
  id: String,
  name: String,
  value: Value,
) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let view = campy_design.set_node_prop(module.form.view, id, name, value)
      case view == module.form.view {
        True -> state
        False ->
          state |> commit_view(module, view) |> set_status("Set " <> name)
      }
    }
  }
}

/// Replace the active module's handler source. One undo entry when it changes.
pub fn set_handlers(state: State, handlers: String) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) ->
      state
      |> commit_handlers(module, handlers)
      |> set_status("Handlers updated")
  }
}

fn commit_handlers(state: State, module: Module, handlers: String) -> State {
  let updated = campy_project.Module(..module, handlers: handlers)

  let modules =
    list.map(state.project.modules, fn(candidate) {
      case candidate.slug == module.slug {
        True -> updated
        False -> candidate
      }
    })

  commit(
    state,
    campy_project.Project(
      title: state.project.title,
      modules: modules,
      extra: state.project.extra,
    ),
  )
}

/// Live typing: replace the active module's handler source without touching
/// undo/redo and without a status line. Scintilla owns text-level undo; the
/// model just has to stay in sync with the buffer so a refresh never
/// reverts typed text.
fn type_handlers(state: State, handlers: String) -> State {
  case active_module(state) {
    Error(_) -> state
    Ok(module) ->
      case module.handlers == handlers {
        True -> state
        False -> {
          let updated = campy_project.Module(..module, handlers: handlers)

          let modules =
            list.map(state.project.modules, fn(candidate) {
              case candidate.slug == module.slug {
                True -> updated
                False -> candidate
              }
            })

          State(
            ..state,
            project: campy_project.Project(
              title: state.project.title,
              modules: modules,
              extra: state.project.extra,
            ),
          )
        }
      }
  }
}

/// The event keys a control declares in the document. The designer view
/// rewrites events to `select`, so always read the module's form, not the
/// canvas subtree.
pub fn control_events(state: State, id: String) -> List(String) {
  case active_module(state) {
    Error(_) -> []
    Ok(module) ->
      case campy_design.find_node(module.form.view, id) {
        Some(node) -> node.events
        None -> []
      }
  }
}

/// Events shown for the shared selection. Multi-selection stays read-only, so
/// only a single control contributes events.
pub fn selected_events(state: State) -> List(String) {
  case state.selection {
    [id] -> control_events(state, id)
    _ -> []
  }
}

pub fn handler_name(control_id: String, event: String) -> String {
  campy_project.handler_name(control_id, event)
}

/// The inspector's cheap existence check: a `pub fn <name>(` declaration is
/// enough; parsing Gleam here would duplicate the compiler.
pub fn handler_exists(handlers: String, name: String) -> Bool {
  string.contains(handlers, "pub fn " <> name <> "(")
}

/// The ABI v2 stub appended when an event has no handler yet.
pub fn handler_stub(name: String) -> String {
  "pub fn "
  <> name
  <> "(state: State, event: Event) -> #(State, List(Effect)) {\n"
  <> "  let _ = event\n"
  <> "  #(state, [])\n"
  <> "}\n"
}

fn append_handler(handlers: String, stub: String) -> String {
  case handlers {
    "" -> stub
    _ ->
      case string.ends_with(handlers, "\n") {
        True -> handlers <> "\n" <> stub
        False -> handlers <> "\n\n" <> stub
      }
  }
}

/// Open a declared event's handler source. Missing handlers are appended as
/// ABI v2 stubs in the active module (one undo entry); both paths show Code.
pub fn open_handler(state: State, control_id: String, event: String) -> State {
  case active_module(state) {
    Error(error) -> set_status(state, error)
    Ok(module) -> {
      let name = handler_name(control_id, event)

      let #(state, status) = case handler_exists(module.handlers, name) {
        True -> #(state, "Opened " <> name)
        False -> {
          let handlers = append_handler(module.handlers, handler_stub(name))
          let state = commit_handlers(state, module, handlers)
          #(state, "Added handler " <> name)
        }
      }

      show_code(state) |> set_status(status)
    }
  }
}

/// Selected controls whose ancestors are not also selected. Deleting or
/// copying a container already covers its children. The form root is not a
/// component: it is never deleted or copied (it is selected, moved and
/// resized through the form plate instead).
fn selected_top(root: Node, ids: List(String)) -> List(Node) {
  list.filter_map(ids, fn(id) {
    case id == root.id {
      True -> Error(Nil)
      False ->
        case campy_design.find_node(root, id) {
          None -> Error(Nil)
          Some(node) ->
            case
              list.any(ids, fn(other) {
                other != id && campy_design.is_within(root, other, id)
              })
            {
              True -> Error(Nil)
              False -> Ok(node)
            }
        }
    }
  })
}

/// Deep copy with fresh, globally unique ids. Keys are dropped because two
/// copies in the same parent must not share a reconciliation key.
fn clone_tree(node: Node, existing: List(String)) -> #(Node, List(String)) {
  let id = fresh_id(existing, node.kind)

  let #(children, existing) =
    list.fold(node.children, #([], [id, ..existing]), fn(acc, child) {
      let #(children, existing) = acc
      let #(clone, existing) = clone_tree(child, existing)
      #(list.append(children, [clone]), existing)
    })

  #(
    campy_view.Node(
      kind: node.kind,
      id: id,
      key: None,
      props: node.props,
      events: node.events,
      children: children,
      extra: node.extra,
    ),
    existing,
  )
}

fn fresh_id(existing: List(String), kind: String) -> String {
  let prefix = kind <> "_"

  let highest =
    list.fold(existing, 0, fn(highest, id) {
      case string.starts_with(id, prefix) {
        True ->
          case int.parse(string.drop_start(id, string.length(prefix))) {
            Ok(number) -> int.max(highest, number)
            Error(_) -> highest
          }
        False -> highest
      }
    })

  prefix <> int.to_string(highest + 1)
}

fn parent_origin_for(
  layout: campy_design.Layout,
  desired: dict.Dict(String, campy_design.Rect),
  id: String,
) -> #(Int, Int) {
  case campy_design.placed(layout, id) {
    Some(placed) ->
      case placed.parent {
        Some(parent_id) ->
          case dict.get(desired, parent_id) {
            Ok(rect) -> #(rect.x, rect.y)
            Error(_) -> campy_design.parent_origin_in(layout, id)
          }
        None -> #(0, 0)
      }
    None -> #(0, 0)
  }
}

fn clipboard_items(root: Node, selection: List(String)) -> List(ClipboardItem) {
  let layout = campy_design.resolve(root)

  list.map(selected_top(root, selection), fn(node) {
    let rect = case campy_design.placed(layout, node.id) {
      Some(placed) -> placed.rect
      None ->
        campy_design.Rect(
          0,
          0,
          campy_design.default_w(node.kind),
          campy_design.default_h(node.kind),
        )
    }
    ClipboardItem(node: node, rect: rect)
  })
}

fn parent_frame(
  layout: campy_design.Layout,
  parent_id: String,
) -> #(Int, Int, Int, Int) {
  case campy_design.placed(layout, parent_id) {
    Some(placed) -> #(
      placed.rect.x,
      placed.rect.y,
      placed.rect.w,
      placed.rect.h,
    )
    None -> #(0, 0, 640, 480)
  }
}

/// Offset a copied control by 16 px, convert to the target parent's space, and
/// keep it inside that parent so a paste into a small container is visible.
fn paste_rect(
  source: campy_design.Rect,
  ox: Int,
  oy: Int,
  ow: Int,
  oh: Int,
) -> campy_design.Rect {
  let x = source.x + 16 - ox
  let y = source.y + 16 - oy
  let max_x = int.max(0, ow - source.w)
  let max_y = int.max(0, oh - source.h)

  campy_design.Rect(
    x: int.max(0, int.min(x, max_x)),
    y: int.max(0, int.min(y, max_y)),
    w: source.w,
    h: source.h,
  )
}

/// Record a running app actor. The app publishes into its own top-level
/// window (the shell opens it); the notebook stays on the user's page.
pub fn run_started(state: State, running: campy_app.Running) -> State {
  State(..state, running: Some(running), live_view: None)
  |> log("Running " <> running.slug)
  |> set_status("")
}

/// Store the latest published view from the running app.
pub fn run_view(
  state: State,
  document: campy_view.Document,
  gen: Int,
) -> State {
  State(..state, live_view: Some(document))
  |> log("view generation " <> int.to_string(gen))
}

/// A running-app console line.
pub fn run_report(state: State, text: String) -> State {
  log(state, text)
}

/// The running app's code was updated to `version`; the actor will migrate
/// and republish.
pub fn run_code_updated(state: State, version: Int) -> State {
  case state.running {
    None -> state
    Some(running) -> {
      let running = campy_app.Running(..running, version: version)
      State(..state, running: Some(running))
      |> log("code updated to version " <> int.to_string(version))
    }
  }
}

/// The running app stopped (or was never started).
pub fn run_stopped(state: State) -> State {
  State(..state, running: None, live_view: None)
  |> log("App stopped")
}

/// Record a freshly started peer.
pub fn peer_started(state: State, peer: Peer) -> State {
  let known = list.any(state.peers, fn(p) { p.node == peer.node })
  let peers = case known {
    True -> state.peers
    False -> list.append(state.peers, [peer])
  }
  State(..state, peers: peers, selected_peer: Some(peer.node))
  |> log("peer " <> peer.node <> " started")
  |> set_status("")
}

/// A peer was stopped and is gone.
pub fn peer_stopped(state: State, node: String) -> State {
  let peers = list.filter(state.peers, fn(p) { p.node != node })
  let selected = case state.selected_peer {
    Some(selected) if selected == node -> None
    _ -> state.selected_peer
  }
  // An app attached to that peer's node is gone with it.
  let state = case state.running {
    Some(running) if running.node == node ->
      State(..state, running: None, live_view: None)
    _ -> state
  }
  State(..state, peers: peers, selected_peer: selected)
  |> log("peer " <> node <> " stopped")
}

/// The peer the app tree selection points at.
pub fn peer_selected(state: State, node: String) -> State {
  State(..state, selected_peer: Some(node))
}

/// A peer vanished (down/crashed); detach anything attached to it.
pub fn peer_gone(state: State, node: String) -> State {
  let peers = list.filter(state.peers, fn(p) { p.node != node })
  let state = case state.running {
    Some(running) if running.node == node -> {
      let state = State(..state, running: None, live_view: None)
      log(state, "peer " <> node <> " is down; app detached")
    }
    _ -> state
  }
  State(..state, peers: peers)
}

/// The selected (or only) peer, if any.
pub fn selected_peer(state: State) -> Result(Peer, String) {
  case state.selected_peer {
    Some(node) ->
      case list.find(state.peers, fn(p) { p.node == node }) {
        Ok(peer) -> Ok(peer)
        Error(Nil) -> first_peer(state)
      }
    None -> first_peer(state)
  }
}

fn first_peer(state: State) -> Result(Peer, String) {
  case state.peers {
    [peer, ..] -> Ok(peer)
    [] -> Error("no peer nodes; start one on the Nodes page")
  }
}

/// Peer node names for the nodes list.
pub fn peer_nodes(state: State) -> List(String) {
  list.map(state.peers, fn(peer) { peer.node })
}

/// Peer names for the app tree, `node` plus the apps attached to it.
pub fn peer_lines(state: State) -> List(String) {
  let apps = case state.running {
    Some(running) if running.node != "" -> [running.slug]
    _ -> []
  }
  case state.peers {
    [] -> ["(no peers)"]
    peers ->
      list.flat_map(peers, fn(peer) {
        case apps {
          [] -> [peer.node]
          apps -> [peer.node, ..list.map(apps, fn(app) { "  " <> app })]
        }
      })
  }
}

/// The generated module name for the active form, per ABI v2 dispatch.
pub fn run_module(state: State) -> Result(String, String) {
  case active_module(state) {
    Error(error) -> Error(error)
    Ok(module) -> Ok(campy_appgen.module_name(module.slug))
  }
}

pub fn update(state: State, command: Command) -> State {
  case command {
    OpenModule(slug) ->
      case open_module(state, slug) {
        Ok(state) -> state
        Error(error) -> set_status(state, error)
      }
    CloseModule(slug) -> close_module(state, slug)
    SelectControls(ids) -> select_controls(state, ids)
    Commit(project) -> commit(state, project)
    Undo -> undo(state)
    Redo -> redo(state)
    Log(line) -> log(state, line)
    SetStatus(text) -> set_status(state, text)
    ToggleCodeView -> toggle_code_view(state)
    ToggleSourceView -> toggle_source_view(state)
    ShowForm -> show_form_page(state)
    ShowCode -> show_code_page(state)
    ShowSource -> show_source_page(state)
    ClearConsole -> clear_console(state)
    Arm(kind) -> arm(state, kind)
    Disarm -> disarm(state)
    PlaceWidget(kind, x, y, w, h) -> place_widget(state, kind, x, y, w, h)
    CopySelection -> copy_selection(state)
    CutSelection -> cut_selection(state)
    Paste -> paste(state)
    DuplicateSelection -> duplicate_selection(state)
    DeleteSelection -> delete_selection(state)
    BringToFront -> bring_to_front(state)
    SendToBack -> send_to_back(state)
    CommitGeometry(items, reparent) -> commit_geometry(state, items, reparent)
    RunStarted(running) -> run_started(state, running)
    RunView(document, gen) -> run_view(state, document, gen)
    RunReport(text) -> run_report(state, text)
    RunCodeUpdated(version) -> run_code_updated(state, version)
    RunStopped -> run_stopped(state)
    PeerStarted(peer) -> peer_started(state, peer)
    PeerStopped(node) -> peer_stopped(state, node)
    PeerSelected(node) -> peer_selected(state, node)
    PeerGone(node) -> peer_gone(state, node)
    SetNodesName(name) -> State(..state, nodes_name: name)
    ShowNodes ->
      State(..state, page: NodesPage, nodes_view: True, debug_view: False)
    ShowDebug ->
      State(..state, page: DebugPage, debug_view: True, nodes_view: False)
    TracingStarted(tracer) ->
      State(..state, tracer: Some(tracer))
      |> log("tracing send/receive on the app actor")
    TracingStopped -> State(..state, tracer: None)
    SetControlRect(id, rect) -> set_control_rect(state, id, rect)
    SetControlProp(id, name, value) -> set_control_prop(state, id, name, value)
    SetHandlers(handlers) -> set_handlers(state, handlers)
    TypedHandlers(handlers) -> type_handlers(state, handlers)
    OpenHandler(control_id, event) -> open_handler(state, control_id, event)
    LspStarted(client) ->
      State(..state, lsp: Lsp(..state.lsp, client: Some(client)))
    LspDown(reason) -> State(..state, lsp: no_lsp()) |> log(reason)
    LspPushed(file, version, text) -> {
      let diags = case state.lsp.file == Some(file) {
        True -> state.lsp.diags
        False -> []
      }

      State(
        ..state,
        lsp: Lsp(
          ..state.lsp,
          file: Some(file),
          text: text,
          version: version,
          diags: diags,
        ),
      )
    }
    LspDiagnostics(file, rows) ->
      case state.lsp.file == Some(file) {
        True -> State(..state, lsp: Lsp(..state.lsp, diags: rows))
        False -> state
      }
    ApplySettings(settings) -> apply_settings(state, settings)
  }
}

/// Console lines as one block, newest last, for a text pane.
pub fn console_text(state: State) -> String {
  state.console
  |> list.reverse
  |> list.intersperse("\n")
  |> list.fold("", fn(acc, line) { acc <> line })
}

/// A compact status line: active module, selection count, undo depth.
pub fn status_line(state: State) -> String {
  let module = case state.active {
    Some(slug) -> slug
    None -> "—"
  }
  let selection = int.to_string(list.length(state.selection))
  let history = int.to_string(list.length(state.undo))
  module <> "  sel:" <> selection <> "  undo:" <> history
}
