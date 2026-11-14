import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// CCL — the Campy Component Library.
//
// The catalog models Slint's component model: every component declares the
// properties it exposes (name, editor kind, default) and the callbacks it
// emits, matching the Slint standard widgets where one exists. Where Slint
// has no widget (radio button, menu, picture) the closest Slint semantics
// are used. Layout (Free/Column/Row), geometry, enabled/visible and color
// are properties of every element and live on the form model, not here.
//
// No backward compatibility with pre-schema projects is preserved; Campy
// itself is the only consumer.

pub type PropType {
  /// Single-line string, edited with a LineEdit.
  Text
  /// Whole number, edited with a numeric LineEdit.
  Number
  /// True/false, edited with a CheckBox.
  Bool
}

pub type Property {
  Property(key: String, label: String, kind: PropType, default: String)
}

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
    properties: List(Property),
    events: List(Event),
  )
}

// Property keys reused across components.
pub const text_key = "text"

pub const placeholder_key = "placeholder-text"

pub const read_only_key = "read-only"

pub const checked_key = "checked"

pub const minimum_key = "minimum"

pub const maximum_key = "maximum"

pub const current_index_key = "current-index"

fn read_only_prop() -> Property {
  Property(read_only_key, "Read only", Bool, "false")
}

fn checked_prop() -> Property {
  Property(checked_key, "Checked", Bool, "false")
}

pub fn all() -> List(Component) {
  [
    Component("label", "Label", "T", "Common", 240, 24, "Label", False, [], []),
    Component(
      "edit",
      "Edit",
      "▭",
      "Common",
      240,
      32,
      "",
      False,
      [
        Property(placeholder_key, "Placeholder", Text, ""),
        read_only_prop(),
      ],
      [Event("accepted", "OnAccepted"), Event("edited", "OnEdited")],
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
      [read_only_prop()],
      [Event("edited", "OnEdited")],
    ),
    Component("button", "Button", "□", "Common", 110, 32, "Button", False, [], [
      Event("clicked", "OnClicked"),
    ]),
    Component("menu", "Menu", "☰", "Common", 200, 28, "File", False, [], [
      Event("selected", "OnSelect"),
    ]),
    Component(
      "checkbox",
      "Check box",
      "☑",
      "Common",
      150,
      28,
      "Check box",
      False,
      [checked_prop()],
      [Event("toggled", "OnToggle")],
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
      [checked_prop()],
      [Event("toggled", "OnToggle")],
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
      [Property(current_index_key, "Current index", Number, "0")],
      [Event("selected", "OnSelect")],
    ),
    Component("list", "List", "≡", "Common", 300, 160, "", False, [], []),
    Component(
      "slider",
      "Slider",
      "━",
      "Values",
      200,
      32,
      "50",
      False,
      [
        Property(minimum_key, "Minimum", Number, "0"),
        Property(maximum_key, "Maximum", Number, "100"),
      ],
      [Event("changed", "OnChange"), Event("released", "OnRelease")],
    ),
    Component(
      "progress",
      "Progress",
      "▰",
      "Values",
      200,
      24,
      "60",
      False,
      [],
      [],
    ),
    Component(
      "panel",
      "Panel",
      "▣",
      "Containers",
      320,
      200,
      "Panel",
      True,
      [],
      [],
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
      [],
      [],
    ),
    Component("picture", "Picture", "▧", "Common", 200, 150, "", False, [], []),
  ]
}

pub fn find(key: String) -> Option(Component) {
  option.from_result(list.find(all(), fn(component) { component.key == key }))
}

// The property schema for one component kind (may be empty for unknown keys).
pub fn properties(kind_key: String) -> List(Property) {
  case find(kind_key) {
    Some(component) -> component.properties
    None -> []
  }
}

// The event schema for one component kind.
pub fn events(kind_key: String) -> List(Event) {
  case find(kind_key) {
    Some(component) -> component.events
    None -> []
  }
}

// The declared default for one property of one kind; "" when unknown.
pub fn prop_default(kind_key: String, prop_key: String) -> String {
  case
    list.find(properties(kind_key), fn(property) { property.key == prop_key })
  {
    Ok(property) -> property.default
    Error(_) -> ""
  }
}

// The label for one property of one kind; falls back to the raw key.
pub fn prop_label(kind_key: String, prop_key: String) -> String {
  case
    list.find(properties(kind_key), fn(property) { property.key == prop_key })
  {
    Ok(property) -> property.label
    Error(_) -> prop_key
  }
}

// The event label for one kind/event pair; "" when unknown.
pub fn event_label(kind_key: String, event_key: String) -> String {
  events(kind_key)
  |> list.find(fn(event) { event.key == event_key })
  |> result.map(fn(event: Event) { event.label })
  |> result.unwrap("")
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
