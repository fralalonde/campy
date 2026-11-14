import campy_form
import gleam/option.{type Option, None, Some}
import gleam/string

// Handler ABI v1: handlers are the existing zero-argument functions
// `pub fn <control_name>_<event_key>() -> Nil`. ABI v2 (a context argument)
// is future work; nothing in the dispatch path assumes it here.

// The handler function name for a control/event pair. Control names, not ids,
// carry the generated handler prefix, so the form is the canonical lookup.
pub fn name_for(
  form: campy_form.Form,
  control_id: String,
  event_key: String,
) -> Option(String) {
  case campy_form.find_control(form, control_id) {
    Some(control) -> Some(campy_form.handler_name(control, event_key))
    None -> None
  }
}

// Run one event handler through the dynamic-dispatch FFI. All handler failures
// are values, never raises: the app actor must survive every handler error.
pub fn run(
  form: campy_form.Form,
  handlers_module: String,
  control_id: String,
  event_key: String,
) -> Result(Nil, String) {
  case name_for(form, control_id, event_key) {
    Some(function) -> apply_handler(handlers_module, function)
    None -> Error("no handler")
  }
}

@external(erlang, "campy_app_ffi", "apply_handler")
pub fn apply_handler(module: String, function: String) -> Result(Nil, String)

// Same shape as campy_ide.short_error: first line only, capped at 180 chars.
pub fn truncate(reason: String) -> String {
  case string.split(reason, "\n") {
    [first, ..] -> string.slice(first, 0, 180)
    [] -> ""
  }
}
