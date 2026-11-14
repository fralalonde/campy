import campy_ccl
import campy_form.{
  type Control, type Form, Button, CheckBox, ComboBox, EditBox, GroupBox, Label,
  ListBox, Memo, Menu, Panel, Picture, Progress, RadioButton, Slider,
}
import gleam/float
import gleam/int
import gleam/list

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
  let border = campy_form.border_of(form, "")
  case form.layout {
    campy_form.Free ->
      // Render order matches the designer canvas (containers before children,
      // siblings in z-order), so reordering is reflected in the run window.
      string.join(
        list.map(campy_form.render_controls(form), fn(control) {
          control_element(form, control, True)
        }),
        "",
      )
    campy_form.Column ->
      "    ScrollView { width: 100%; height: 100%;\n"
      <> "      VerticalLayout { padding: "
      <> px(border)
      <> "; spacing: 8px;\n"
      <> string.join(
        list.map(campy_form.render_controls(form), fn(control) {
          indent(control_element(form, control, False))
        }),
        "",
      )
      <> "      }\n"
      <> "    }\n"
    campy_form.Row ->
      "    HorizontalLayout { padding: "
      <> px(border)
      <> "; spacing: 8px; height: 100%;\n"
      <> string.join(
        list.map(campy_form.render_controls(form), fn(control) {
          indent(control_element(form, control, False))
        }),
        "",
      )
      <> "    }\n"
  }
}

fn callbacks(form: Form) -> String {
  form.controls
  |> list.flat_map(callbacks_for)
  |> string.join("")
}

// One Slint callback per declared event. Edit-like widgets pass the new
// text; the rest are plain notifications.
fn callbacks_for(control: Control) -> List(String) {
  let kind = kind_key(control)
  campy_ccl.events(kind)
  |> list.map(fn(event: campy_ccl.Event) {
    let handler = campy_form.handler_name(control, event.key)
    case kind {
      "edit" -> "  callback " <> handler <> "(string);\n"
      _ -> "  callback " <> handler <> "();\n"
    }
  })
}

fn kind_key(control: Control) -> String {
  campy_form.kind_key(control.kind)
}

fn control_element(form: Form, control: Control, free: Bool) -> String {
  let geometry = case free {
    True -> {
      let #(x, y, width, height) = campy_form.bounds(form, control)
      "x: "
      <> px(x)
      <> "; y: "
      <> px(y)
      <> "; width: "
      <> px(width)
      <> "; height: "
      <> px(height)
      <> "; clip: true;"
    }
    False -> "width: 100%; height: " <> px(control.height) <> "; clip: true;"
  }
  case control.kind {
    Panel | GroupBox -> {
      let color = campy_form.color_of(form, control.id)
      "    Rectangle { "
      <> geometry
      <> " visible: "
      <> bool(control.visible)
      <> "; background: "
      <> color_value(color, "#20242c")
      <> "; border-width: 1px; border-color: #3a3f4b; border-radius: 4px;\n"
      <> "      Text { x: 8px; y: 6px; text: "
      <> quote(control.text)
      <> "; color: "
      <> text_color(color)
      <> "; font-weight: 600; }\n"
      <> "    }\n"
    }
    _ ->
      "    Rectangle { "
      <> geometry
      <> " visible: "
      <> bool(control.visible)
      <> ";\n"
      <> outer_inner(form, control)
      <> "    }\n"
  }
}

fn outer_inner(form: Form, control: Control) -> String {
  case control.kind {
    Label ->
      "      Text { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; color: "
      <> text_color(campy_form.color_of(form, control.id))
      <> "; vertical-alignment: center; }\n"
    EditBox ->
      "      LineEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; placeholder-text: "
      <> quote(campy_form.control_prop(
        control,
        "placeholder-text",
        campy_ccl.prop_default(kind_of(control), "placeholder-text"),
      ))
      <> "; read-only: "
      <> bool(
        campy_form.control_prop(
          control,
          "read-only",
          campy_ccl.prop_default(kind_of(control), "read-only"),
        )
        == "true",
      )
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; edited(text) => { root."
      <> handler_or(control, "edited")
      <> "(text); }\n"
      <> "        accepted(text) => { root."
      <> handler_or(control, "accepted")
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
          <> "); image-fit: contain;"
          <> opacity_suffix(form, control.id)
          <> " }\n"
      }
    Memo ->
      "      TextEdit { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; read-only: "
      <> bool(campy_form.control_prop(control, "read-only", "false") == "true")
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; edited => { root."
      <> handler_or(control, "edited")
      <> "(); } }\n"
    CheckBox ->
      "      CheckBox { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> "; checked: "
      <> checked_of(control)
      <> "; enabled: "
      <> bool(control.enabled)
      <> "; toggled => { root."
      <> handler_or(control, "toggled")
      <> "(); } }\n"
    RadioButton ->
      "      Rectangle { x: 0; y: (parent.height - 18px) / 2; width: 18px; height: 18px; border-radius: 9px; border-width: 1px; border-color: Palette.foreground; background: transparent; }\n"
      <> "      Rectangle { x: 5px; y: (parent.height - 8px) / 2; width: 8px; height: 8px; border-radius: 4px; background: Palette.accent-background; visible: "
      <> checked_of(control)
      <> "; }\n"
      <> "      Text { x: 26px; y: 0; height: parent.height; text: "
      <> quote(control.text)
      <> "; color: Palette.foreground; vertical-alignment: center; }\n"
      <> "      TouchArea { clicked => { root."
      <> handler_or(control, "toggled")
      <> "(); } }\n"
    ComboBox ->
      "      ComboBox { x: 0; y: 0; width: parent.width; height: parent.height; model: "
      <> combo_model(control)
      <> "; current-index: "
      <> int.to_string(int.max(
        0,
        int_prop(
          control,
          "current-index",
          case
            int.parse(campy_ccl.prop_default(kind_of(control), "current-index"))
          {
            Ok(value) -> value
            Error(_) -> 0
          },
        ),
      ))
      <> "; selected => { root."
      <> handler_or(control, "selected")
      <> "(); } }\n"
    Slider ->
      "      Slider { x: 0; y: 0; width: parent.width; height: parent.height; minimum: "
      <> int.to_string(slider_minimum(control))
      <> ".0; maximum: "
      <> int.to_string(slider_maximum(control))
      <> ".0; value: "
      <> int.to_string(value_of(control))
      <> ".0; changed => { root."
      <> handler_or(control, "changed")
      <> "(); }"
      <> " released => { root."
      <> handler_or(control, "released")
      <> "(); } }\n"
    Progress ->
      "      ProgressIndicator { x: 0; y: (parent.height - 6px) / 2; width: parent.width; height: 6px; progress: "
      <> int.to_string(value_of(control))
      <> ".0 / 100.0; }\n"
    Menu -> {
      let area = menu_area(control.id)
      "      "
      <> area
      <> " := ContextMenuArea {\n"
      <> "        Button { x: 0; y: 0; width: parent.width; height: parent.height; text: "
      <> quote(control.text)
      <> " + \"  ▾\"; enabled: "
      <> bool(control.enabled)
      <> "; clicked => { "
      <> area
      <> ".show({ x: 0px, y: self.height }); } }\n"
      <> "        Menu {\n"
      <> "          MenuItem { title: \"Item 1\"; activated => { root."
      <> handler_or(control, "selected")
      <> "(); } }\n"
      <> "          MenuItem { title: \"Item 2\"; activated => { root."
      <> handler_or(control, "selected")
      <> "(); } }\n"
      <> "        }\n"
      <> "      }\n"
    }
    Panel | GroupBox -> ""
  }
}

// A per-control color: empty means the theme default.
fn text_color(hex: String) -> String {
  case hex {
    "" -> "Palette.foreground"
    _ -> hex
  }
}

fn color_value(hex: String, default: String) -> String {
  case hex {
    "" -> default
    _ -> hex
  }
}

fn menu_area(id: String) -> String {
  "context_menu_"
  <> {
    id
    |> string.replace("-", "_")
    |> string.replace(".", "_")
  }
}

fn value_of(control: Control) -> Int {
  case int.parse(control.text) {
    Ok(value) -> int.max(0, int.min(100, value))
    Error(_) -> 50
  }
}

// Picture transparency: 0 keeps the image fully opaque, 100 makes it invisible.
fn opacity_suffix(form: campy_form.Form, id: String) -> String {
  let transparency = campy_form.transparency_of(form, id)
  case transparency {
    0 -> ""
    _ ->
      " opacity: "
      <> float.to_string(1.0 -. int.to_float(transparency) /. 100.0)
      <> ";"
  }
}

fn handler_or(control: Control, event_key: String) -> String {
  campy_form.handler_name(control, event_key)
}

// Property helpers: values come from the control's props with CCL defaults.
fn kind_of(control: Control) -> String {
  campy_form.kind_key(control.kind)
}

fn checked_of(control: Control) -> String {
  bool(
    campy_form.control_prop(
      control,
      "checked",
      campy_ccl.prop_default(kind_of(control), "checked"),
    )
    == "true",
  )
}

fn int_prop(control: Control, key: String, default: Int) -> Int {
  case
    int.parse(campy_form.control_prop(control, key, int.to_string(default)))
  {
    Ok(value) -> value
    Error(_) -> default
  }
}

fn slider_minimum(control: Control) -> Int {
  int_prop(control, "minimum", 0)
}

fn slider_maximum(control: Control) -> Int {
  int_prop(control, "maximum", 100)
}

// The combo's items are its text, comma separated, like the designer's editor.
fn combo_model(control: Control) -> String {
  let items =
    control.text
    |> string.split(",")
    |> list.map(fn(item) { quote(string.trim(item)) })
    |> string.join(", ")
  "[" <> items <> "]"
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
