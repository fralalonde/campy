import gleam/option.{type Option}

// The resource carries session identity and ownership, never a live Slint handle.
pub type Session

pub type Command {
  LoadUi(generation: Int, source: String)
  SetText(generation: Int, property: String, value: String)
  SetBool(generation: Int, property: String, value: Bool)
  SetInt(generation: Int, property: String, value: Int)
  SetModel(generation: Int, property: String, items: List(WireValue))
  SetColor(generation: Int, property: String, value: String)
  ReadText(generation: Int, property: String)
  Resize(generation: Int, width: Int, height: Int)
  Snapshot(generation: Int, path: String)
}

pub type NativeEvent {
  NativeEvent(session: Int, generation: Int, kind: String, payload: String)
}

// Generic value used by SetModel. Structs and nested lists map to Slint
// structs/models, letting the host drive `for` loops at runtime.
pub type WireValue {
  WireText(String)
  WireBool(Bool)
  WireInt(Int)
  WireList(List(WireValue))
  WireStruct(List(#(String, WireValue)))
  WireImage(String)
}

@external(erlang, "campy_bridge_ffi", "protocol_version")
pub fn protocol_version() -> Int

// Headless validation only; no UI handles are created or retained.
@external(erlang, "campy_bridge_ffi", "validate_ui")
pub fn validate_ui(source: String) -> Result(Int, String)

@external(erlang, "campy_bridge_ffi", "open_session")
pub fn open_session() -> Result(Session, String)

@external(erlang, "campy_bridge_ffi", "session_id")
pub fn session_id(session: Session) -> Result(Int, String)

// Success means enqueued. Completion and diagnostics arrive as native events.
@external(erlang, "campy_bridge_ffi", "submit")
pub fn submit(session: Session, command: Command) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "close_session")
pub fn close_session(session: Session) -> Result(Nil, String)

@external(erlang, "campy_bridge_ffi", "poll")
pub fn poll(timeout_ms: Int) -> Option(NativeEvent)
