import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// CCL — the Campy Component Library.
//
// The catalog speaks wire protocol v2 (`docs/PHASE2.md` §1.4): every
// component's `key` is a protocol `ControlDesc.kind`, its `properties` are the
// props the renderer reads, and its `events` are the `control:<id>:<event>`
// suffixes the host emits. Layout (Free/Column/Row), geometry, enabled,
// visible and color are properties of every element and live on the form
// model, not here.
//
// zgui mapping, one line per kind:
//
//   label        -> `text`
//   edit         -> zgui-ui `Input` (`placeholder`, `read-only`; accepted/edited)
//   memo         -> `editor` element (`read-only`; edited)
//   button       -> campy-styled `control` button (`variant`; clicked)
//   menu         -> button + `Menu` popup (`model`; clicked/selected)
//   checkbox     -> zgui-ui `Checkbox` (`checked`; toggled)
//   radio        -> `Checkbox` in the radio role (`checked`, `group`; toggled)
//   combo        -> zgui-ui `Combobox` (`model`, `current-index`; selected)
//   list         -> `VirtualList` rows of `label` (`model`; selected)
//   slider       -> zgui-ui `Slider` (`minimum`, `maximum`, `value`; changed)
//   progress     -> zgui-ui `Progress` (`value`, `maximum`; changed)
//   picture      -> `image` (`source`, `fit`, `transparency`)
//   panel, group -> `box` containers (`layout`, `border`; children at geometry)
//   code_editor  -> zgui-editor `Editor` (`language`, `read-only`,
//                   `line-numbers`; edited)
//   console      -> zgui-terminal `Terminal` (input arrives as
//                   `console:<id>:input`, not a `control:` event)
//
// `text` is the CCL-universal property: for every kind it is the primary
// caption/value, carried as `ControlDesc.text` (not a `props` entry) and
// edited through the inspector's text row.
//
// `surface` is deliberately absent: the designer canvas is IDE-internal and
// never appears in the palette.
//
// No backward compatibility with pre-schema projects is preserved; Campy
// itself is the only consumer.

pub type PropType {
  /// Single-line string, edited with a text field.
  Text
  /// Whole number, edited with a numeric field.
  Number
  /// True/false, edited with a checkbox.
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

// Property keys reused across components. These are the wire `props` keys the
// zgui host reads, not display strings.
pub const text_key = "text"

pub const placeholder_key = "placeholder"

pub const read_only_key = "read-only"

pub const checked_key = "checked"

pub const group_key = "group"

pub const model_key = "model"

pub const current_index_key = "current-index"

pub const minimum_key = "minimum"

pub const maximum_key = "maximum"

pub const value_key = "value"

pub const variant_key = "variant"

pub const layout_key = "layout"

pub const border_key = "border"

pub const source_key = "source"

pub const fit_key = "fit"

pub const transparency_key = "transparency"

pub const language_key = "language"

pub const line_numbers_key = "line-numbers"

// The CCL-universal property: the control's primary caption/value.
fn text_prop(default: String) -> Property {
  Property(text_key, "Text", Text, default)
}

fn read_only_prop(default: Bool) -> Property {
  Property(read_only_key, "Read only", Bool, bool_string(default))
}

fn checked_prop() -> Property {
  Property(checked_key, "Checked", Bool, "false")
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub fn all() -> List(Component) {
  [
    // zgui `text`: a plain caption.
    Component(
      "label",
      "Label",
      "T",
      "Common",
      240,
      24,
      "Label",
      False,
      [text_prop("Label")],
      [],
    ),
    // zgui-ui `Input`: single-line text with a placeholder.
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
        text_prop(""),
        Property(placeholder_key, "Placeholder", Text, ""),
        read_only_prop(False),
      ],
      [Event("accepted", "OnAccepted"), Event("edited", "OnEdited")],
    ),
    // zgui-editor `editor` element: multi-line text.
    Component(
      "memo",
      "Memo",
      "≣",
      "Common",
      260,
      100,
      "",
      False,
      [text_prop(""), read_only_prop(False)],
      [Event("edited", "OnEdited")],
    ),
    // Campy-styled `control` button; `variant` picks solid/outline.
    Component(
      "button",
      "Button",
      "□",
      "Common",
      110,
      32,
      "Button",
      False,
      [text_prop("Button"), Property(variant_key, "Variant", Text, "solid")],
      [Event("clicked", "OnClicked")],
    ),
    // `Button` with a `Menu` popup; `model` is the item list.
    Component(
      "menu",
      "Menu",
      "☰",
      "Common",
      200,
      28,
      "File",
      False,
      [text_prop("File"), Property(model_key, "Items", Text, "")],
      [Event("clicked", "OnClicked"), Event("selected", "OnSelect")],
    ),
    // zgui-ui `Checkbox`.
    Component(
      "checkbox",
      "Check box",
      "☑",
      "Common",
      150,
      28,
      "Check box",
      False,
      [text_prop("Check box"), checked_prop()],
      [Event("toggled", "OnToggle")],
    ),
    // zgui-ui `Checkbox` in the radio role; `group` scopes exclusivity.
    Component(
      "radio",
      "Radio button",
      "○",
      "Common",
      150,
      28,
      "Radio button",
      False,
      [
        text_prop("Radio button"),
        checked_prop(),
        Property(group_key, "Group", Text, ""),
      ],
      [Event("toggled", "OnToggle")],
    ),
    // zgui-ui `Combobox`; `model` is the item list.
    Component(
      "combo",
      "Combo box",
      "▼",
      "Common",
      180,
      32,
      "",
      False,
      [
        text_prop(""),
        Property(model_key, "Items", Text, ""),
        Property(current_index_key, "Current index", Number, "0"),
      ],
      [Event("selected", "OnSelect")],
    ),
    // zgui-ui `VirtualList` of `label` rows; `model` is the row list.
    Component(
      "list",
      "List",
      "≡",
      "Common",
      300,
      160,
      "",
      False,
      [text_prop(""), Property(model_key, "Items", Text, "")],
      [Event("selected", "OnSelect")],
    ),
    // zgui-ui `Slider`.
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
        text_prop("50"),
        Property(minimum_key, "Minimum", Number, "0"),
        Property(maximum_key, "Maximum", Number, "100"),
        Property(value_key, "Value", Number, "50"),
      ],
      [Event("changed", "OnChange")],
    ),
    // zgui-ui `Progress`.
    Component(
      "progress",
      "Progress",
      "▰",
      "Values",
      200,
      24,
      "60",
      False,
      [
        text_prop("60"),
        Property(value_key, "Value", Number, "60"),
        Property(maximum_key, "Maximum", Number, "100"),
      ],
      [Event("changed", "OnChange")],
    ),
    // zgui `box` container; children position at their geometry.
    Component(
      "panel",
      "Panel",
      "▣",
      "Containers",
      320,
      200,
      "Panel",
      True,
      [
        text_prop("Panel"),
        Property(layout_key, "Layout", Text, "free"),
        Property(border_key, "Border", Number, "0"),
      ],
      [],
    ),
    // zgui `box` container with a group caption.
    Component(
      "group",
      "Group box",
      "⊞",
      "Containers",
      320,
      200,
      "Group",
      True,
      [
        text_prop("Group"),
        Property(layout_key, "Layout", Text, "free"),
        Property(border_key, "Border", Number, "0"),
      ],
      [],
    ),
    // zgui `image`; `source` is a file path, `fit` a CSS object-fit value.
    Component(
      "picture",
      "Picture",
      "▧",
      "Common",
      200,
      150,
      "",
      False,
      [
        text_prop(""),
        Property(source_key, "Source", Text, ""),
        Property(fit_key, "Fit", Text, "contain"),
        Property(transparency_key, "Transparency", Number, "0"),
      ],
      [],
    ),
    // zgui-editor `Editor` with the Gleam grammar.
    Component(
      "code_editor",
      "Code editor",
      "⌨",
      "Common",
      400,
      300,
      "",
      False,
      [
        text_prop(""),
        Property(language_key, "Language", Text, "gleam"),
        read_only_prop(False),
        Property(line_numbers_key, "Line numbers", Bool, "true"),
      ],
      [Event("edited", "OnEdited")],
    ),
    // zgui-terminal `Terminal` over the BEAM-fed transport.
    Component(
      "console",
      "Console",
      "▥",
      "Common",
      480,
      240,
      "",
      False,
      [text_prop("")],
      [],
    ),
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
