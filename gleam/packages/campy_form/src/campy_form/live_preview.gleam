//// Form → protocol-v2 document emitter.
////
//// `to_controls` turns the designer model into the `ControlDesc` tree a
//// `LoadUi` carries: the window becomes the tree root (a `panel` with the
//// form's layout and border), its controls nest under their adopting
//// container, and every kind carries the props `campy_ccl` declares for it.
//// Geometry is CSS px; a Free container positions its children absolutely,
//// Column/Row containers flow them (the renderer uses the box layout classes)
//// so their width/height are the arranging dimension.
////
//// Dependency rule: this module imports `campy_bridge` for its wire *types*
//// only. It builds `ControlDesc`/`WireValue` values and never calls a bridge
//// function, so `campy_form` stays free of any NIF/session dependency.
////
//// Control ids: `ControlDesc.id` is an integer, the form model stores string
//// ids. `campy_form.control_wire_id` derives the stable wire id (a hash of the
//// string id, with 0 reserved for the window root), so a regenerated document
//// keeps every control's id and later ops address the same control. The same
//// grammar gives the IDE shell its section ids (`campy_form.wire_id("menu-bar")`).

import campy_bridge.{
  type ControlDesc, type WireValue, ControlDesc, WireBool, WireImage, WireInt,
  WireList, WireText,
}
import campy_ccl
import campy_form.{type Control, type Form, type Layout}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

/// The `ControlDesc.id` of the window root. Control ids are positive
/// (`campy_form.control_wire_id`), so 0 can never collide with one.
pub const window_id = campy_form.window_id

/// The root kind: a plain container box (no caption), carrying the form's
/// layout and border so the renderer enters Free/Column/Row mode at the window.
pub const root_kind = "panel"

/// The whole UI document for one form: a single root node whose children are
/// the form's controls (nested under their containers, in render order).
pub fn to_controls(form: Form) -> List(ControlDesc) {
  [
    ControlDesc(
      id: window_id,
      kind: root_kind,
      text: form.title,
      x: 0,
      y: 0,
      w: form.width,
      h: form.height,
      enabled: True,
      visible: True,
      props: container_props(form, ""),
      children: describe_all(
        form,
        root_controls(form),
        form.layout,
        #(0, 0, form.width, form.height),
        [],
      ),
    ),
  ]
}

// The window's own children: unparented controls plus any whose parent entry
// points at a control that no longer exists (the model renders those at the
// top level too, so a stale form never loses a control silently).
fn root_controls(form: Form) -> List(Control) {
  list.filter(form.controls, fn(control) {
    case campy_form.parent_of(form, control.id) {
      "" -> True
      parent -> campy_form.find_control(form, parent) == None
    }
  })
}

fn describe_all(
  form: Form,
  controls: List(Control),
  parent_layout: Layout,
  parent_box: #(Int, Int, Int, Int),
  ancestors: List(String),
) -> List(ControlDesc) {
  controls
  |> list.filter(fn(control) { !list.contains(ancestors, control.id) })
  |> list.map(fn(control) {
    describe(form, control, parent_layout, parent_box, [control.id, ..ancestors])
  })
}

fn describe(
  form: Form,
  control: Control,
  parent_layout: Layout,
  parent_box: #(Int, Int, Int, Int),
  ancestors: List(String),
) -> ControlDesc {
  let #(px, py, pw, ph) = parent_box
  let #(ax, ay, aw, ah) = campy_form.bounds(form, control)
  let #(w, h) = case parent_layout {
    campy_form.Column -> #(inner_span(form, control, pw), ah)
    campy_form.Row -> #(aw, inner_span(form, control, ph))
    campy_form.Free -> #(aw, ah)
  }
  ControlDesc(
    id: campy_form.control_wire_id(control),
    kind: campy_form.kind_key(control.kind),
    // A non-visual component has no content of its own: its *name* is what the
    // designer tile has to show, and what a reader would call it.
    text: case campy_form.non_visual(control.kind) {
      True -> control.name
      False -> control.text
    },
    x: ax - px,
    y: ay - py,
    w:,
    h:,
    enabled: control.enabled,
    visible: control.visible,
    props: control_props(form, control),
    children: describe_all(
      form,
      campy_form.children_of(form, control.id),
      campy_form.layout_of(form, control.id),
      #(ax, ay, aw, ah),
      ancestors,
    ),
  )
}

// The arranging dimension of a Column/Row child: the parent's inner span, so
// the child fills the flow (the renderer reads width/height, not left/top).
fn inner_span(form: Form, control: Control, parent_span: Int) -> Int {
  let border =
    campy_form.border_of(form, campy_form.parent_of(form, control.id))
  int.max(1, parent_span - border * 2)
}

fn container_props(form: Form, id: String) -> List(#(String, WireValue)) {
  [
    #("layout", WireText(campy_form.layout_key(campy_form.layout_of(form, id)))),
    #("border", WireInt(campy_form.border_of(form, id))),
  ]
}

// Every property `campy_ccl` declares for the kind, in catalog order. The
// universal `text` row is `ControlDesc.text`, never a props entry.
fn control_props(form: Form, control: Control) -> List(#(String, WireValue)) {
  let kind = campy_form.kind_key(control.kind)
  case control.kind {
    campy_form.Panel | campy_form.GroupBox -> container_props(form, control.id)
    _ ->
      campy_ccl.properties(kind)
      |> list.filter(fn(property) { property.key != campy_ccl.text_key })
      |> list.map(fn(property) {
        #(property.key, prop_value(form, control, kind, property))
      })
  }
}

fn prop_value(
  form: Form,
  control: Control,
  kind: String,
  property: campy_ccl.Property,
) -> WireValue {
  case property.key {
    key if key == campy_ccl.placeholder_key ->
      WireText(prop_text(control, kind, key))
    key if key == campy_ccl.group_key -> WireText(prop_text(control, kind, key))
    key if key == campy_ccl.variant_key ->
      WireText(prop_text(control, kind, key))
    key if key == campy_ccl.fit_key -> WireText(prop_text(control, kind, key))
    key if key == campy_ccl.language_key ->
      WireText(prop_text(control, kind, key))
    key if key == campy_ccl.read_only_key ->
      WireBool(prop_bool(control, kind, key))
    key if key == campy_ccl.checked_key ->
      WireBool(prop_bool(control, kind, key))
    key if key == campy_ccl.line_numbers_key ->
      WireBool(prop_bool(control, kind, key))
    key if key == campy_ccl.model_key -> WireList(model_items(control, kind))
    key if key == campy_ccl.current_index_key ->
      WireInt(prop_int(control, kind, key))
    key if key == campy_ccl.minimum_key -> WireInt(prop_int(control, kind, key))
    key if key == campy_ccl.maximum_key -> WireInt(prop_int(control, kind, key))
    key if key == campy_ccl.value_key -> WireInt(value_of(control, kind))
    key if key == campy_ccl.transparency_key ->
      WireInt(campy_form.transparency_of(form, control.id))
    // A file path, so it crosses as the protocol's image value (§1.4).
    key if key == campy_ccl.source_key -> WireImage(control.text)
    _ -> default_value(control, property)
  }
}

// A property the form model does not drive yet: the control's own value or the
// CCL default, converted by the catalog's property type.
fn default_value(control: Control, property: campy_ccl.Property) -> WireValue {
  let raw = campy_form.control_prop(control, property.key, property.default)
  case property.kind {
    campy_ccl.Text -> WireText(raw)
    campy_ccl.Bool -> WireBool(raw == "true")
    campy_ccl.Number ->
      case int.parse(string.trim(raw)) {
        Ok(value) -> WireInt(value)
        Error(_) -> WireInt(0)
      }
  }
}

fn prop_text(control: Control, kind: String, key: String) -> String {
  campy_form.control_prop(control, key, campy_ccl.prop_default(kind, key))
}

fn prop_bool(control: Control, kind: String, key: String) -> Bool {
  prop_text(control, kind, key) == "true"
}

fn prop_int(control: Control, kind: String, key: String) -> Int {
  case int.parse(string.trim(prop_text(control, kind, key))) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

// The slider/progress value: the `value` prop when the inspector set it,
// otherwise the control's text (the primary value field), otherwise the CCL
// default.
fn value_of(control: Control, kind: String) -> Int {
  let raw = campy_form.control_prop(control, campy_ccl.value_key, control.text)
  case int.parse(string.trim(raw)) {
    Ok(value) -> value
    Error(_) -> prop_int(control, kind, campy_ccl.value_key)
  }
}

// Model items are comma separated, like the inspector's Items row. A control
// without an explicit model falls back to its text (the designer convention for
// combo/list items, preserved from the previous preview).
fn model_items(control: Control, kind: String) -> List(WireValue) {
  let declared =
    campy_form.control_prop(
      control,
      campy_ccl.model_key,
      campy_ccl.prop_default(kind, campy_ccl.model_key),
    )
  let raw = case string.trim(declared) {
    "" -> control.text
    _ -> declared
  }
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
  |> list.map(WireText)
}
