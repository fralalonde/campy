import campy_form.{
  type Control, type Form, Button, CheckBox, ComboBox, EditBox, GroupBox, Label,
  ListBox, Memo, Panel, Picture, Progress, RadioButton, Slider,
}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// Emits the standalone window shown when the IDE runs the module. Free forms
// use absolute positions; Column/Row forms let Slint lay the controls out.
pub fn to_slint(form: Form) -> Result(String, String) {
  case campy_form.validate(form) {
    Error(error) -> Error(error)
    Ok(_) ->
      Ok(
        "import { Button, CheckBox, ComboBox, LineEdit, ListView, Palette, ProgressIndicator, ScrollView, Slider, TextEdit } from \"std-widgets.slint\";\n"
        <> "export component CampyPreview inherits Window {\n"
        <> "  title: "
        <> quote(form.title)
        <> ";\n"
        <> "  preferred-width: "
        <> px(form.width)
        <> ";\n"
        <> "  preferred-height: "
        <> px(form.height)
        <> ";\n"
        <> "  min-width: 240px;\n"
        <> "  min-height: 160px;\n"
        <> callbacks(form)
        <> "  Rectangle { width: 100%; height: 100%; background: Palette.background;\n"
        <> content(form)
        <> "\n  }\n"
        <> "}\n",
      )
  }
}

fn content(form: Form) -> String {
  case form.layout {
    campy_form.Free ->
      string.join(
        list.map(form.controls, fn(control) {
          control_element(form, control, True)
        }),
        "",
      )
    campy_form.Column ->
      "    ScrollView { width: 100%; height: 100%;\n"
      <> "      VerticalLayout { padding: 8px; spacing: 8px;\n"
      <> string.join(
        list.map(form.controls, fn(control) {
          indent(control_element(form, control, False))
        }),
        "",
      )
      <> "      }\n"
      <> "    }\n"
    campy_form.Row ->
      "    HorizontalLayout { padding: 8px; spacing: 8px; height: 100%;\n"
      <> string.join(
        list.map(form.controls, fn(control) {
          indent(control_element(form, control, False))
        }),
        "",
      )
      <> "    }\n"
  }
}

fn callbacks(form: Form) -> String {
  form.controls
  |> list.filter_map(callback)
  |> string.join("")
}

fn callback(control: Control) -> Result(String, Nil) {
  case control.kind {
    Label | ListBox | Panel | GroupBox | Picture | Progress -> Error(Nil)
    EditBox ->
      case campy_form.handler_name(control) {
        Some(handler) -> Ok("  callback " <> handler <> "(string);\n")
        None -> Error(Nil)
      }
    Memo | Button | CheckBox | RadioButton | ComboBox | Slider ->
      case campy_form.handler_name(control) {
        Some(handler) -> Ok("  callback " <> handler <> "();\n")
        None -> Error(Nil)
      }
  }
}

fn control_element(form: Form, control: Control, free: Bool) -> String {
  let geometry = case free {
    True ->
      case campy_form.align_of(form, control.id) {
        campy_form.NoAlign ->
          "x: "
          <> px(control.x)
          <> "; y: "
          <> px(control.y)
          <> "; width: "
          <> px(control.width)
          <> "; height: "
          <> px(control.height)
          <> "; clip: true;"
        campy_form.Top ->
          "x: 0; y: 0; width: parent.width; height: "
          <> px(control.height)
          <> "; clip: true;"
        campy_form.Bottom ->
          "x: 0; y: parent.height - "
          <> px(control.height)
          <> "; width: parent.width; height: "
          <> px(control.height)
          <> "; clip: true;"
        campy_form.Left ->
          "x: 0; y: 0; width: "
          <> px(control.width)
          <> "; height: parent.height; clip: true;"
        campy_form.Right ->
          "x: parent.width - "
          <> px(control.width)
          <> "; y: 0; width: "
          <> px(control.width)
          <> "; height: parent.height; clip: true;"
        campy_form.Client ->
          "x: 0; y: 0; width: parent.width; height: parent.height; clip: true;"
      }
    False ->
      case control.kind {
        _ -> "width: 100%; height: " <> px(control.height) <> "; clip: true;"
      }
  }
  case control.kind {
    Panel | GroupBox ->
      "    Rectangle { "
      <> geometry
      <> " visible: "
      <> bool(control.visible)
      <> "; background: #20242c; border-width: 1px; border-color: #3a3f4b; border-radius: 4px;\n"
      <> "      Text { x: 8px; y: 6px; text: "
      <> quote(control.text)
      <> "; color: Palette.foreground; font-weight: 600; }\n"
      <> "    }\n"
    _ ->
      "    Rectangle { "
      <> geometry
      <> " visible: "
      <> bool(control.visible)
      <> ";\n"
      <> outer_inner(control)
      <> "    }\n"
  }
}

fn outer_inner(control: Control) -> String {
  case control.kind {
    Label ->
      "      Text { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; color: Palette.foreground; vertical-alignment: center; }\n"
    EditBox ->
      "      LineEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; edited(text) => { root."
      <> handler_or(control, "changed")
      <> "(text); } }\n"
    Button ->
      "      Button { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; clicked => { root."
      <> handler_or(control, "clicked")
      <> "(); } }\n"
    ListBox ->
      "      ListView { x: 0; y: 0; width: parent.width; height: parent.height;\n"
      <> "        for item in [\"First item\", \"Second item\", \"Third item\", \"Fourth item\", \"Fifth item\"]: Rectangle { height: 26px;\n"
      <> "          Text { x: 8px; y: 0; height: parent.height; text: item; color: Palette.foreground; vertical-alignment: center; }\n"
      <> "        }\n"
      <> "      }\n"
    Picture ->
      case control.text {
        "" -> ""
        path ->
          "      Image { x: 0; y: 0; width: parent.width; height: parent.height; source: @image-url("
          <> quote(path)
          <> "); image-fit: contain; }\n"
      }
    Memo ->
      "      TextEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; edited => { root."
      <> handler_or(control, "changed")
      <> "(); } }\n"
    CheckBox ->
      "      CheckBox { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; toggled => { root."
      <> handler_or(control, "toggled")
      <> "(); } }\n"
    RadioButton ->
      "      Rectangle { x: 0; y: (parent.height - 18px) / 2; width: 18px; height: 18px; border-radius: 9px; border-width: 1px; border-color: Palette.foreground; background: transparent; }\n"
      <> "      Rectangle { x: 5px; y: (parent.height - 8px) / 2; width: 8px; height: 8px; border-radius: 4px; background: Palette.accent-background; }\n"
      <> "      Text { x: 26px; y: 0; height: parent.height; text: "
      <> quote(control.text)
      <> "; color: Palette.foreground; vertical-alignment: center; }\n"
      <> "      TouchArea { clicked => { root."
      <> handler_or(control, "clicked")
      <> "(); } }\n"
    ComboBox ->
      "      ComboBox { x: 0; y: 0; width: parent.width; height: parent.height; model: [\"First\", \"Second\", \"Third\"]; current-index: 0; selected => { root."
      <> handler_or(control, "selected")
      <> "(); } }\n"
    Slider ->
      "      Slider { x: 0; y: 0; width: parent.width; height: parent.height; minimum: 0.0; maximum: 100.0; value: "
      <> int.to_string(value_of(control))
      <> ".0; changed => { root."
      <> handler_or(control, "changed")
      <> "(); } }\n"
    Progress ->
      "      ProgressIndicator { x: 0; y: (parent.height - 6px) / 2; width: parent.width; height: 6px; progress: "
      <> int.to_string(value_of(control))
      <> ".0 / 100.0; }\n"
    Panel | GroupBox -> ""
  }
}

fn value_of(control: Control) -> Int {
  case int.parse(control.text) {
    Ok(value) -> int.max(0, int.min(100, value))
    Error(_) -> 50
  }
}

fn handler_or(control: Control, fallback: String) -> String {
  case campy_form.handler_name(control) {
    Some(handler) -> handler
    None -> fallback
  }
}

fn indent(text: String) -> String {
  "    " <> text
}

fn px(value: Int) -> String {
  int.to_string(value) <> "px"
}

fn bool(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub fn quote(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
  |> fn(escaped) { "\"" <> escaped <> "\"" }
}
