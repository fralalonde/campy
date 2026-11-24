//// Transition-window stub (Z2.1).
////
//// This module used to emit the standalone Slint window for a run module
//// (`to_slint`). Protocol v2 has no source generation: `campy_form/live_preview`
//// derives the `ControlDesc` document instead, so the Slint emission and its
//// helpers are gone.
////
//// `quote` survives only because `campy_ide` (the Slint-era `ide_ui`/`shell`
//// generated-source view) still imports it; Z2.2/Z2.3 remove that view and this
//// module with it.

import gleam/string

pub fn quote(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
  |> fn(escaped) { "\"" <> escaped <> "\"" }
}
