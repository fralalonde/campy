import gleam/list
import gleam/option.{type Option, None, Some}

// CCL — the Campy Component Library.
//
// The component catalog is inspired by the Lazarus Component Library's basic
// controls (TLabel, TEdit, TButton, TListBox, TPanel, TImage, ...). Where the
// LCL and Slint models differ, Slint's model wins: properties use Slint
// semantics, layouts are Slint layouts (Free/Column/Row), and the emitted
// widgets are Slint standard widgets when one exists.
pub type Event {
  Event(key: String, label: String)
}

pub type Component {
  Component(
    key: String,
    label: String,
    icon: String,
    category: String,
    default_width: Int,
    default_height: Int,
    default_text: String,
    accepts_children: Bool,
    event: Option(Event),
  )
}

pub fn all() -> List(Component) {
  [
    Component("label", "Label", "T", "Common", 240, 24, "Label", False, None),
    Component(
      "edit",
      "Edit",
      "▭",
      "Common",
      240,
      32,
      "",
      False,
      Some(Event("changed", "OnTextChanged")),
    ),
    Component(
      "memo",
      "Memo",
      "≣",
      "Common",
      260,
      100,
      "",
      False,
      Some(Event("changed", "OnTextChanged")),
    ),
    Component(
      "button",
      "Button",
      "□",
      "Common",
      110,
      32,
      "Button",
      False,
      Some(Event("clicked", "OnClick")),
    ),
    Component(
      "checkbox",
      "Check box",
      "☑",
      "Common",
      150,
      28,
      "Check box",
      False,
      Some(Event("toggled", "OnToggle")),
    ),
    Component(
      "radio",
      "Radio button",
      "○",
      "Common",
      150,
      28,
      "Radio button",
      False,
      Some(Event("clicked", "OnClick")),
    ),
    Component(
      "combo",
      "Combo box",
      "▼",
      "Common",
      180,
      32,
      "",
      False,
      Some(Event("selected", "OnSelect")),
    ),
    Component("list", "List", "≡", "Common", 300, 160, "", False, None),
    Component(
      "slider",
      "Slider",
      "━",
      "Values",
      200,
      32,
      "50",
      False,
      Some(Event("changed", "OnChange")),
    ),
    Component("progress", "Progress", "▰", "Values", 200, 24, "60", False, None),
    Component(
      "panel",
      "Panel",
      "▣",
      "Containers",
      320,
      200,
      "Panel",
      True,
      None,
    ),
    Component(
      "group",
      "Group box",
      "⊞",
      "Containers",
      320,
      200,
      "Group",
      True,
      None,
    ),
    Component("picture", "Picture", "▧", "Common", 200, 150, "", False, None),
  ]
}

pub fn find(key: String) -> Option(Component) {
  case list.find(all(), fn(component) { component.key == key }) {
    Ok(component) -> Some(component)
    Error(_) -> None
  }
}

pub fn palette_label(component: Component) -> String {
  component.icon <> "  " <> component.label
}

pub fn categories() -> List(String) {
  ["Common", "Containers", "Values"]
}

pub fn components_in(category: String) -> List(Component) {
  list.filter(all(), fn(component) { component.category == category })
}
