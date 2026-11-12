import campy_form.{type Form, type Layout, Free}
import gleam/int
import gleam/list

// Live preview shell for the app under development. Unlike the static emitter
// used for the generated-Slint tab, this window is loaded once and then driven
// by models and properties. Pressing F6 re-sends the current form, so the
// running app updates in place (no window restart).
pub type PreviewControl {
  PreviewControl(
    id: String,
    kind: String,
    text: String,
    x: Int,
    y: Int,
    w: Int,
    h: Int,
    enabled: Bool,
    visible: Bool,
    picture: String,
    value: Int,
  )
}

pub type Snapshot {
  Snapshot(
    title: String,
    width: Int,
    height: Int,
    layout: Layout,
    border: Int,
    controls: List(PreviewControl),
  )
}

pub fn snapshot(form: Form) -> Snapshot {
  Snapshot(
    form.title,
    form.width,
    form.height,
    form.layout,
    campy_form.border_of(form, ""),
    list.map(campy_form.render_controls(form), fn(control) {
      let #(x, y, w, h) = case form.layout {
        Free -> campy_form.bounds(form, control)
        campy_form.Column | campy_form.Row -> #(
          control.x,
          control.y,
          control.width,
          control.height,
        )
      }
      PreviewControl(
        control.id,
        campy_form.kind_key(control.kind),
        control.text,
        x,
        y,
        w,
        h,
        control.enabled,
        control.visible,
        case control.kind {
          campy_form.Picture -> control.text
          _ -> ""
        },
        control_value(control),
      )
    }),
  )
}

pub fn to_slint() -> String {
  "import { Button, CheckBox, ComboBox, LineEdit, ListView, Palette, ProgressIndicator, ScrollView, Slider, TextEdit } from \"std-widgets.slint\";\n"
  <> "struct PreviewControl { id: string, kind: string, text: string, x: length, y: length, w: length, h: length, enabled: bool, visible: bool, picture: image, value: float }\n"
  <> component()
  <> "export component CampyPreview inherits Window {\n"
  <> "  title: root.app-title;\n"
  <> "  preferred-width: root.form-w;\n"
  <> "  preferred-height: root.form-h;\n"
  <> "  min-width: 240px;\n"
  <> "  min-height: 160px;\n"
  <> "  in-out property <string> app-title: \"Campy app\";\n"
  <> "  in-out property <length> form-w: 640px;\n"
  <> "  in-out property <length> form-h: 420px;\n"
  <> "  in-out property <[PreviewControl]> control-items: [];\n"
  <> "  in-out property <bool> layout-free: true;\n"
  <> "  in-out property <bool> layout-column: false;\n"
  <> "  in-out property <bool> layout-row: false;\n"
  <> "  in-out property <length> form-border: 0px;\n"
  <> "  callback event(string);\n"
  <> "  Rectangle { width: 100%; height: 100%; background: Palette.background;\n"
  <> free_layout()
  <> column_layout()
  <> row_layout()
  <> "  }\n"
  <> "}\n"
}

fn free_layout() -> String {
  "    if root.layout-free: Rectangle { x: 0; y: 0; width: 100%; height: 100%;\n"
  <> "      for control in root.control-items: PreviewItem {\n"
  <> "        data: control;\n"
  <> "        x: control.x; y: control.y; width: control.w; height: control.h;\n"
  <> "        event(payload) => { root.event(payload); }\n"
  <> "      }\n"
  <> "    }\n"
}

fn column_layout() -> String {
  "    if root.layout-column: ScrollView { width: 100%; height: 100%;\n"
  <> "      VerticalLayout { padding: root.form-border; spacing: 8px;\n"
  <> "        for control in root.control-items: PreviewItem {\n"
  <> "          data: control; width: 100%; height: control.h;\n"
  <> "          event(payload) => { root.event(payload); }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
}

fn row_layout() -> String {
  "    if root.layout-row: ScrollView { width: 100%; height: 100%;\n"
  <> "      HorizontalLayout { padding: root.form-border; spacing: 8px; height: 100%;\n"
  <> "        for control in root.control-items: PreviewItem {\n"
  <> "          data: control; width: control.w; height: 100%;\n"
  <> "          event(payload) => { root.event(payload); }\n"
  <> "        }\n"
  <> "      }\n"
  <> "    }\n"
}

fn component() -> String {
  "component PreviewItem inherits Rectangle {\n"
  <> "  in property <PreviewControl> data;\n"
  <> "  callback event(string);\n"
  <> "  clip: true;\n"
  <> "  border-width: data.kind == \"label\" || data.kind == \"picture\" || data.kind == \"checkbox\" || data.kind == \"radio\" ? 0px : 1px;\n"
  <> "  border-color: Palette.border;\n"
  <> "  background: data.kind == \"panel\" || data.kind == \"group\" ? Palette.control-background : transparent;\n"
  <> "  opacity: data.visible ? 1 : 0.35;\n"
  <> "  if data.kind == \"label\": Text { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; color: Palette.foreground; vertical-alignment: center; }\n"
  <> "  if data.kind == \"edit\": LineEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; edited(text) => { root.event(data.id + \":changed\"); } }\n"
  <> "  if data.kind == \"memo\": TextEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; edited => { root.event(data.id + \":changed\"); } }\n"
  <> "  if data.kind == \"button\": Button { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; clicked => { root.event(data.id + \":clicked\"); } }\n"
  <> "  if data.kind == \"checkbox\": CheckBox { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text; enabled: data.enabled; toggled => { root.event(data.id + \":toggled\"); } }\n"
  <> "  if data.kind == \"radio\": Rectangle { x: 0; y: (parent.height - 18px) / 2; width: 18px; height: 18px; border-radius: 9px; border-width: 1px; border-color: Palette.foreground; background: transparent; }\n"
  <> "  if data.kind == \"radio\": Rectangle { x: 5px; y: (parent.height - 8px) / 2; width: 8px; height: 8px; border-radius: 4px; background: Palette.accent-background; }\n"
  <> "  if data.kind == \"radio\": Text { x: 26px; y: 0; height: parent.height; text: data.text; color: Palette.foreground; vertical-alignment: center; }\n"
  <> "  if data.kind == \"radio\": TouchArea { clicked => { root.event(data.id + \":clicked\"); } }\n"
  <> "  if data.kind == \"combo\": ComboBox { x: 0; y: 0; width: parent.width; height: parent.height; model: [\"First\", \"Second\", \"Third\"]; current-index: 0; selected => { root.event(data.id + \":selected\"); } }\n"
  <> "  if data.kind == \"list\": ListView { x: 0; y: 0; width: parent.width; height: parent.height;\n"
  <> "    for item in [\"First item\", \"Second item\", \"Third item\", \"Fourth item\", \"Fifth item\"]: Rectangle { height: 26px;\n"
  <> "      Text { x: 8px; y: 0; height: parent.height; text: item; color: Palette.foreground; vertical-alignment: center; }\n"
  <> "    }\n"
  <> "  }\n"
  <> "  if data.kind == \"slider\": Slider { x: 0; y: 0; width: parent.width; height: parent.height; minimum: 0.0; maximum: 100.0; value: data.value; enabled: data.enabled; changed => { root.event(data.id + \":changed\"); } }\n"
  <> "  if data.kind == \"progress\": ProgressIndicator { x: 0; y: (parent.height - 6px) / 2; width: parent.width; height: 6px; progress: data.value / 100.0; }\n"
  <> "  if data.kind == \"panel\" || data.kind == \"group\": Text { x: 8px; y: 6px; text: data.text; color: Palette.foreground; font-weight: 600; }\n"
  <> "  if data.kind == \"picture\": Image { x: 0; y: 0; width: parent.width; height: parent.height; source: data.picture; image-fit: contain; }\n"
  <> "  if data.kind == \"menu\": menu-area := ContextMenuArea {\n"
  <> "    Button { x: 0; y: 0; width: parent.width; height: parent.height; text: data.text + \"  ▾\"; enabled: data.enabled; clicked => { menu-area.show({ x: 0px, y: self.height }); } }\n"
  <> "    Menu {\n"
  <> "      MenuItem { title: \"Item 1\"; activated => { root.event(data.id + \":selected\"); } }\n"
  <> "      MenuItem { title: \"Item 2\"; activated => { root.event(data.id + \":selected\"); } }\n"
  <> "    }\n"
  <> "  }\n"
  <> "}\n\n"
}

fn control_value(control: campy_form.Control) -> Int {
  case int.parse(control.text) {
    Ok(value) -> int.max(0, int.min(100, value))
    Error(_) -> 50
  }
}
