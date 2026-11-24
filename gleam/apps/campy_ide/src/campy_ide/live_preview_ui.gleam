import campy_bridge as bridge
import campy_form
import campy_form/live_preview

// Transition-window shim (Z2.1): derive a module's preview document and load it
// into an app window.
//
// The preview window is a plain `LoadUi` of the form's `ControlDesc` tree; there
// is no per-load compile and no snapshot/model command sequence any more.
// Reloading after an edit is the same call with a fresh generation.
//
// Z2.3 owns the IDE loop's real preview flow (which also forwards granular
// updates and routes `control:<id>:*` events); this module only preserves the
// IDE's preview seam until then.
pub fn load(
  session: bridge.Session,
  generation: Int,
  form: campy_form.Form,
  theme: String,
) -> Result(Nil, String) {
  case campy_form.validate(form) {
    Error(error) -> Error(error)
    Ok(_) ->
      bridge.submit(
        session,
        bridge.LoadUi(
          generation,
          form.title,
          form.width,
          form.height,
          theme,
          live_preview.to_controls(form),
        ),
      )
  }
}
