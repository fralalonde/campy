import campy_bridge
import gleam/option.{type Option, None, Some}

/// True when a native event belongs to the runner's session. `None` means the
/// runner started without a session id (or lost it across a restart); in that
/// case events are forwarded, matching a standalone app whose VM has one poll
/// owner feeding one session.
pub fn accepts(session: Option(Int), event: campy_bridge.NativeEvent) -> Bool {
  case session {
    Some(id) -> event.session == id
    None -> True
  }
}
