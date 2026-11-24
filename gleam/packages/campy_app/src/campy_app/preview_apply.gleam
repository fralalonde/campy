import campy_bridge as bridge
import campy_form
import campy_form/live_preview

// Load (or reload) an app's preview window from its form: one protocol-v2
// `LoadUi` carrying the `ControlDesc` document `campy_form/live_preview`
// derives. This module lives in campy_app, not campy_form, so the form package
// keeps its bridge *types* dependency and never opens a session.
//
// The app actor reloads the whole document on `apply_snapshot`; granular
// updates (SetText/SetGeometry per control) belong to the IDE's preview flow
// (Z2.3), not to a running app's form reload.
pub const default_theme = "light"

pub fn apply(
  session: bridge.Session,
  generation: Int,
  form: campy_form.Form,
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
          default_theme,
          live_preview.to_controls(form),
        ),
      )
  }
}
