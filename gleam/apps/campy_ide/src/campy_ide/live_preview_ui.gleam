import campy_bridge as bridge
import campy_form
import campy_form/live_preview
import gleam/list
import gleam/result

// Push a live preview snapshot into the already-loaded app window.
pub fn apply(
  session: bridge.Session,
  snapshot: live_preview.Snapshot,
) -> Result(Nil, String) {
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetText(1, "app-title", snapshot.title),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetInt(1, "form-w", snapshot.width),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetInt(1, "form-h", snapshot.height),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetInt(1, "form-border", snapshot.border),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetBool(1, "layout-free", snapshot.layout == campy_form.Free),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetBool(1, "layout-column", snapshot.layout == campy_form.Column),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetBool(1, "layout-row", snapshot.layout == campy_form.Row),
  ))
  use _ <- result.try(bridge.submit(
    session,
    bridge.SetModel(1, "control-items", wire(snapshot.controls)),
  ))
  bridge.submit(session, bridge.Resize(1, snapshot.width, snapshot.height))
}

pub fn wire(
  controls: List(live_preview.PreviewControl),
) -> List(bridge.WireValue) {
  list.map(controls, fn(control) {
    bridge.WireStruct([
      #("id", bridge.WireText(control.id)),
      #("kind", bridge.WireText(control.kind)),
      #("text", bridge.WireText(control.text)),
      #("x", bridge.WireInt(control.x)),
      #("y", bridge.WireInt(control.y)),
      #("w", bridge.WireInt(control.w)),
      #("h", bridge.WireInt(control.h)),
      #("enabled", bridge.WireBool(control.enabled)),
      #("visible", bridge.WireBool(control.visible)),
      #("picture", bridge.WireImage(control.picture)),
      #("value", bridge.WireInt(control.value)),
    ])
  })
}
