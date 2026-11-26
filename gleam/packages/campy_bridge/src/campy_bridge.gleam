import gleam/option.{type Option}

// The resource carries session identity and ownership, never a live UI handle.
pub type Session

// Wire protocol v2: a `LoadUi` document plus granular ops that address the
// controls it created by id. Variant names are the wire terms and must stay
// in sync with `rust/crates/campy-bridge/src/lib.rs`.
pub type WireValue {
  WireText(String)
  WireBool(Bool)
  WireInt(Int)
  WireFloat(Float)
  WireList(List(WireValue))
  WireStruct(List(#(String, WireValue)))
  WireImage(String)
}

/// One designed control (kind keys per `campy_ccl`; geometry in CSS px).
pub type ControlDesc {
  ControlDesc(
    id: Int,
    kind: String,
    text: String,
    x: Int,
    y: Int,
    w: Int,
    h: Int,
    enabled: Bool,
    visible: Bool,
    props: List(#(String, WireValue)),
    children: List(ControlDesc),
  )
}

pub type Command {
  LoadUi(
    generation: Int,
    title: String,
    width: Int,
    height: Int,
    theme: String,
    controls: List(ControlDesc),
  )
  SetText(generation: Int, control: Int, value: String)
  SetBool(generation: Int, control: Int, key: String, value: Bool)
  SetInt(generation: Int, control: Int, key: String, value: Int)
  SetFloat(generation: Int, control: Int, key: String, value: Float)
  SetModel(generation: Int, control: Int, items: List(WireValue))
  SetGeometry(generation: Int, control: Int, x: Int, y: Int, w: Int, h: Int)
  SetCode(generation: Int, control: Int, source: String)
  AppendConsole(generation: Int, control: Int, bytes: String)
  SetMarks(
    generation: Int,
    control: Int,
    layer: String,
    items: List(#(Int, Int, String)),
  )
  ReadText(generation: Int, control: Int, key: String)
  Resize(generation: Int, width: Int, height: Int)
  /// Asks the window for a different pointer (the editor's cursor names:
  /// `default`, `grab`, `grabbing`, `move`, `ew`, `ns`, `nwse`, `nesw`).
  SetCursor(generation: Int, cursor: String)
  /// Several commands that belong to one moment, applied as one. One submit
  /// is one wake and one frame: a gesture that used to wake the window per
  /// changed field now wakes it once.
  Batch(generation: Int, commands: List(Command))
}

/// One native event. Kinds:
///   `ui-loaded`, `closed`, `command-failed`, `runtime-failed`,
///   `session-opened`
///   `control:<id>:<event>`   (clicked, toggled, edited, accepted, selected, changed)
///   `pointer:<id>:<phase>`   (down, move, up, wheel) with `"x;y"` payload
///   `editor:<id>:changed`    full source, debounced
///   `read:<id>:<key>`        replies to ReadText
///   `lsp:diagnostics`, `lsp:completions`
pub type NativeEvent {
  NativeEvent(session: Int, generation: Int, kind: String, payload: String)
}

@external(erlang, "campy_bridge_ffi", "protocol_version")
pub fn protocol_version() -> Int

@external(erlang, "campy_bridge_ffi", "open_session")
pub fn open_session() -> Result(Session, String)

@external(erlang, "campy_bridge_ffi", "session_id")
pub fn session_id(session: Session) -> Result(Int, String)

// Success means enqueued. Completion and diagnostics arrive as native events.
@external(erlang, "campy_bridge_ffi", "submit")
pub fn submit(session: Session, command: Command) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "close_session")
pub fn close_session(session: Session) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "active_sessions")
pub fn active_sessions() -> Int

// Drains this process's mailbox of native events (sent by the UI thread).
@external(erlang, "campy_bridge_ffi", "poll")
pub fn poll(timeout_ms: Int) -> Option(NativeEvent)

// The handler-code language server (`gleam lsp`). Results travel through
// the regular event stream as `lsp:completions` / `lsp:diagnostics` events.
pub type Lsp

@external(erlang, "campy_bridge_ffi", "lsp_start")
pub fn lsp_start(root: String) -> Result(Lsp, String)

@external(erlang, "campy_bridge_ffi", "lsp_open")
pub fn lsp_open(lsp: Lsp, uri: String, text: String) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "lsp_change")
pub fn lsp_change(
  lsp: Lsp,
  uri: String,
  version: Int,
  text: String,
) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "lsp_completions")
pub fn lsp_completions(
  lsp: Lsp,
  uri: String,
  line: Int,
  character: Int,
) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "lsp_stop")
pub fn lsp_stop(lsp: Lsp) -> Result(Nil, String)

// Headless smoke driver (NIF built with the `ui-testing` feature).
@external(erlang, "campy_bridge_ffi", "test_pump")
pub fn test_pump(milliseconds: Int) -> Result(Int, String)

@external(erlang, "campy_bridge_ffi", "test_pointer")
pub fn test_pointer(action: String, x: Float, y: Float) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "test_resize")
pub fn test_resize(width: Float, height: Float) -> Result(Nil, String)
