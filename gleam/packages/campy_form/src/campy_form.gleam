import campy_ccl
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// Designer model. Controls are stored flat with absolute geometry; a parent map
// records adoption so panels (and the window root) can own other controls.
pub type Kind {
  Label
  EditBox
  Memo
  Button
  CheckBox
  RadioButton
  ComboBox
  ListBox
  Slider
  Progress
  Panel
  GroupBox
  Picture
  Menu
}

// How the form arranges its controls. Free is absolute (the classic designer);
// Column and Row delegate placement to Slint layouts.
pub type Layout {
  Free
  Column
  Row
}

// LCL-style alignment, expressed with Slint's layout model. Aligned Free-layout
// controls follow the form's width/height; Column/Row layouts ignore alignment.
pub type Align {
  NoAlign
  Top
  Bottom
  Left
  Right
  Client
}

pub type Control {
  Control(
    id: String,
    name: String,
    kind: Kind,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    text: String,
    enabled: Bool,
    visible: Bool,
  )
}

pub type Form {
  Form(
    id: String,
    title: String,
    width: Int,
    height: Int,
    layout: Layout,
    controls: List(Control),
    parents: List(#(String, String)),
    aligns: List(#(String, Align)),
    layouts: List(#(String, Layout)),
  )
}

pub fn new_form() -> Form {
  Form("campy.form", "Campy Form", 640, 420, Free, [], [], [], [])
}

// Starting project so the IDE opens with something to play with.
pub fn demo_form() -> Form {
  Form(
    "campy.form",
    "Campy Form",
    640,
    420,
    Free,
    [
      Control(
        "label-1",
        "label1",
        Label,
        24,
        24,
        260,
        24,
        "Campy form designer",
        True,
        True,
      ),
      Control("edit-1", "edit1", EditBox, 24, 64, 240, 32, "", True, True),
      Control(
        "button-1",
        "button1",
        Button,
        24,
        112,
        110,
        32,
        "Click me",
        True,
        True,
      ),
    ],
    [],
    [],
    [],
  )
}

pub fn kind_label(kind: Kind) -> String {
  case campy_ccl.find(kind_key(kind)) {
    Some(component) -> component.label
    None -> kind_key(kind)
  }
}

pub fn kind_key(kind: Kind) -> String {
  case kind {
    Label -> "label"
    EditBox -> "edit"
    Memo -> "memo"
    Button -> "button"
    CheckBox -> "checkbox"
    RadioButton -> "radio"
    ComboBox -> "combo"
    ListBox -> "list"
    Slider -> "slider"
    Progress -> "progress"
    Panel -> "panel"
    GroupBox -> "group"
    Picture -> "picture"
    Menu -> "menu"
  }
}

pub fn kind_from_key(key: String) -> Option(Kind) {
  case key {
    "label" -> Some(Label)
    "edit" -> Some(EditBox)
    "memo" -> Some(Memo)
    "button" -> Some(Button)
    "checkbox" -> Some(CheckBox)
    "radio" -> Some(RadioButton)
    "combo" -> Some(ComboBox)
    "list" -> Some(ListBox)
    "slider" -> Some(Slider)
    "progress" -> Some(Progress)
    "panel" -> Some(Panel)
    "group" -> Some(GroupBox)
    "picture" -> Some(Picture)
    "menu" -> Some(Menu)
    _ -> None
  }
}

pub fn layout_key(layout: Layout) -> String {
  case layout {
    Free -> "free"
    Column -> "column"
    Row -> "row"
  }
}

pub fn layout_of(form: Form, parent_id: String) -> Layout {
  case parent_id {
    "" -> form.layout
    _ ->
      case list.find(form.layouts, fn(entry) { entry.0 == parent_id }) {
        Ok(entry) -> entry.1
        Error(_) -> Free
      }
  }
}

pub fn set_layout_for(form: Form, parent_id: String, layout: Layout) -> Form {
  case parent_id {
    "" -> Form(..form, layout: layout)
    _ -> {
      let rest = list.filter(form.layouts, fn(entry) { entry.0 != parent_id })
      case layout {
        Free -> Form(..form, layouts: rest)
        Column | Row ->
          Form(..form, layouts: list.append(rest, [#(parent_id, layout)]))
      }
    }
  }
}

pub fn align_key(align: Align) -> String {
  case align {
    NoAlign -> "none"
    Top -> "top"
    Bottom -> "bottom"
    Left -> "left"
    Right -> "right"
    Client -> "client"
  }
}

pub fn align_label(align: Align) -> String {
  case align {
    NoAlign -> "None (free)"
    Top -> "Top"
    Bottom -> "Bottom"
    Left -> "Left"
    Right -> "Right"
    Client -> "Client"
  }
}

pub fn align_from_key(key: String) -> Align {
  case key {
    "top" -> Top
    "bottom" -> Bottom
    "left" -> Left
    "right" -> Right
    "client" -> Client
    _ -> NoAlign
  }
}

// Effective geometry used by the designer and live preview, including design
// alignment. Column/Row layouts position controls with Slint, so their stored
// geometry is returned for editor-side hit testing only.
pub fn bounds(form: Form, control: Control) -> #(Int, Int, Int, Int) {
  case form.layout {
    Free -> {
      let parent_id = parent_of(form, control.id)
      let #(px, py, pw, ph) = parent_bounds(form, control)
      case layout_of(form, parent_id) {
        Free ->
          case align_of(form, control.id) {
            NoAlign -> #(control.x, control.y, control.width, control.height)
            Top -> #(px, py, pw, control.height)
            Bottom -> #(px, py + ph - control.height, pw, control.height)
            Left -> #(px, py, control.width, ph)
            Right -> #(px + pw - control.width, py, control.width, ph)
            Client -> #(px, py, pw, ph)
          }
        Column -> arranged_column(form, control, parent_id, px, py, pw)
        Row -> arranged_row(form, control, parent_id, px, py, ph)
      }
    }
    Column | Row -> #(control.x, control.y, control.width, control.height)
  }
}

fn arranged_column(
  form: Form,
  control: Control,
  parent_id: String,
  px: Int,
  py: Int,
  pw: Int,
) -> #(Int, Int, Int, Int) {
  let before =
    children_of(form, parent_id)
    |> list.take_while(fn(sibling) { sibling.id != control.id })
  let offset =
    list.fold(before, 8, fn(total, sibling) { total + sibling.height + 6 })
  #(px + 8, py + offset, int.max(8, pw - 16), control.height)
}

fn arranged_row(
  form: Form,
  control: Control,
  parent_id: String,
  px: Int,
  py: Int,
  ph: Int,
) -> #(Int, Int, Int, Int) {
  let before =
    children_of(form, parent_id)
    |> list.take_while(fn(sibling) { sibling.id != control.id })
  let offset =
    list.fold(before, 8, fn(total, sibling) { total + sibling.width + 6 })
  #(px + offset, py + 8, control.width, int.max(8, ph - 16))
}

fn parent_bounds(form: Form, control: Control) -> #(Int, Int, Int, Int) {
  case parent_of(form, control.id) {
    "" -> #(0, 0, form.width, form.height)
    parent_id ->
      case find_control(form, parent_id) {
        Some(parent) -> bounds(form, parent)
        None -> #(0, 0, form.width, form.height)
      }
  }
}

pub fn remove_controls(form: Form, ids: List(String)) -> Form {
  list.fold(ids, form, fn(current, id) { remove_control(current, id) })
}

pub fn container_at(form: Form, x: Int, y: Int) -> String {
  let candidates =
    list.filter(form.controls, fn(candidate) {
      candidate.visible
      && accepts_children(candidate.kind)
      && x >= candidate.x
      && x <= candidate.x + candidate.width
      && y >= candidate.y
      && y <= candidate.y + candidate.height
    })
  case smallest_container(candidates, None) {
    Some(candidate) -> candidate.id
    None -> ""
  }
}

fn smallest_container(
  candidates: List(Control),
  best: Option(Control),
) -> Option(Control) {
  case candidates {
    [] -> best
    [candidate, ..rest] -> {
      let next = case best {
        None -> Some(candidate)
        Some(current) ->
          case
            candidate.width * candidate.height < current.width * current.height
          {
            True -> Some(candidate)
            False -> Some(current)
          }
      }
      smallest_container(rest, next)
    }
  }
}

pub fn align_of(form: Form, id: String) -> Align {
  case list.find(form.aligns, fn(entry) { entry.0 == id }) {
    Ok(entry) -> entry.1
    Error(_) -> NoAlign
  }
}

pub fn set_parent(form: Form, id: String, parent: String) -> Form {
  let cycles = case parent == id {
    True -> True
    False ->
      case parent == "" {
        True -> False
        False -> is_descendant(form, id, parent)
      }
  }
  let missing = case parent == "" {
    True -> False
    False ->
      case find_control(form, parent) {
        Some(_) -> False
        None -> True
      }
  }
  case cycles || missing {
    True -> form
    False -> {
      let without = list.filter(form.parents, fn(entry) { entry.0 != id })
      let parents = case parent {
        "" -> without
        _ -> [#(id, parent), ..without]
      }
      Form(..form, parents: parents)
    }
  }
}

fn is_descendant(form: Form, ancestor: String, id: String) -> Bool {
  case parent_of(form, id) {
    "" -> False
    parent -> parent == ancestor || is_descendant(form, ancestor, parent)
  }
}

// Render order for the designer and previews: a container is drawn before its
// children, so adopted controls are visible above their panel.
pub fn render_controls(form: Form) -> List(Control) {
  let roots =
    list.filter(form.controls, fn(control) {
      !has_existing_parent(form, control.id)
    })
  let #(ordered, seen) = visit_controls(roots, form, [], [])
  let remaining =
    list.filter(form.controls, fn(control) { !list.contains(seen, control.id) })
  list.append(ordered, remaining)
}

fn has_existing_parent(form: Form, id: String) -> Bool {
  case list.find(form.parents, fn(entry) { entry.0 == id }) {
    Ok(entry) ->
      entry.1 != ""
      && list.any(form.controls, fn(control) { control.id == entry.1 })
    Error(_) -> False
  }
}

fn visit_controls(
  controls: List(Control),
  form: Form,
  seen: List(String),
  acc: List(Control),
) -> #(List(Control), List(String)) {
  list.fold(controls, #(acc, seen), fn(state, control) {
    let #(acc, seen) = state
    case list.contains(seen, control.id) {
      True -> #(acc, seen)
      False -> {
        let acc = list.append(acc, [control])
        let seen = [control.id, ..seen]
        let children =
          list.filter(form.controls, fn(child) {
            parent_of(form, child.id) == control.id
          })
        visit_controls(children, form, seen, acc)
      }
    }
  })
}

pub fn set_align(form: Form, id: String, align: Align) -> Form {
  let others = list.filter(form.aligns, fn(entry) { entry.0 != id })
  let aligns = case align {
    NoAlign -> others
    _ -> [#(id, align), ..others]
  }
  Form(..form, aligns: aligns)
}

// Panels, group boxes, and the window root accept children.
pub fn accepts_children(kind: Kind) -> Bool {
  case campy_ccl.find(kind_key(kind)) {
    Some(component) -> component.accepts_children
    None -> False
  }
}

fn default_size(kind: Kind) -> #(Int, Int) {
  case campy_ccl.find(kind_key(kind)) {
    Some(component) -> #(component.default_width, component.default_height)
    None -> #(240, 32)
  }
}

fn default_text(kind: Kind) -> String {
  case campy_ccl.find(kind_key(kind)) {
    Some(component) -> component.default_text
    None -> ""
  }
}

// Adds a control. `parent_id` is "" for the window root; panels adopt children
// and position them inside their bounds.
pub fn add_control_rect(
  form: Form,
  kind: Kind,
  parent_id: String,
  x: Int,
  y: Int,
  width: Int,
  height: Int,
) -> #(Form, Control) {
  let prefix = kind_key(kind)
  let suffix = next_suffix(form.controls, prefix, 1)
  let #(default_width, default_height) = default_size(kind)
  let width = case width >= 8 {
    True -> width
    False -> default_width
  }
  let height = case height >= 8 {
    True -> height
    False -> default_height
  }
  let control =
    Control(
      prefix <> "-" <> suffix,
      prefix <> suffix,
      kind,
      int.max(0, int.min(4095, x)),
      int.max(0, int.min(4095, y)),
      int.max(8, int.min(4095, width)),
      int.max(8, int.min(4095, height)),
      default_text(kind),
      True,
      True,
    )
  let parents = list.append(form.parents, [#(control.id, parent_id)])
  #(
    Form(
      ..form,
      controls: list.append(form.controls, [control]),
      parents: parents,
    ),
    control,
  )
}

pub fn add_control(
  form: Form,
  kind: Kind,
  parent_id: String,
) -> #(Form, Control) {
  let prefix = kind_key(kind)
  let suffix = next_suffix(form.controls, prefix, 1)
  let #(width, height) = default_size(kind)
  let #(x, y) = new_position(form, parent_id)
  let control =
    Control(
      prefix <> "-" <> suffix,
      prefix <> suffix,
      kind,
      x,
      y,
      width,
      height,
      default_text(kind),
      True,
      True,
    )
  let parents = list.append(form.parents, [#(control.id, parent_id)])
  #(
    Form(
      ..form,
      controls: list.append(form.controls, [control]),
      parents: parents,
    ),
    control,
  )
}

fn new_position(form: Form, parent_id: String) -> #(Int, Int) {
  case parent_id {
    "" -> {
      let index = list.length(children_of(form, ""))
      #(24 + index / 6 * 200, 24 + index % 6 * 44)
    }
    _ ->
      case find_control(form, parent_id) {
        Some(parent) -> {
          let index = list.length(children_of(form, parent_id))
          #(parent.x + 12, parent.y + 36 + index * 36)
        }
        None -> #(24, 24)
      }
  }
}

fn next_suffix(controls: List(Control), prefix: String, start: Int) -> String {
  let name = prefix <> int.to_string(start)
  case list.any(controls, fn(control) { control.name == name }) {
    True -> next_suffix(controls, prefix, start + 1)
    False -> int.to_string(start)
  }
}

pub fn find_control(form: Form, id: String) -> Option(Control) {
  case list.find(form.controls, fn(control) { control.id == id }) {
    Ok(control) -> Some(control)
    Error(_) -> None
  }
}

pub fn parent_of(form: Form, id: String) -> String {
  case list.find(form.parents, fn(entry) { entry.0 == id }) {
    Ok(entry) -> entry.1
    Error(_) -> ""
  }
}

pub fn children_of(form: Form, id: String) -> List(Control) {
  list.filter(form.controls, fn(control) { parent_of(form, control.id) == id })
}

pub fn descendant_ids(form: Form, id: String) -> List(String) {
  let direct = list.map(children_of(form, id), fn(control) { control.id })
  list.flat_map(direct, fn(child) { [child, ..descendant_ids(form, child)] })
}

pub fn subtree_ids(form: Form, id: String) -> List(String) {
  [id, ..descendant_ids(form, id)]
}

pub fn update_control(form: Form, updated: Control) -> Form {
  Form(
    ..form,
    controls: list.map(form.controls, fn(control) {
      case control.id == updated.id {
        True -> updated
        False -> control
      }
    }),
  )
}

pub fn update_selected(
  form: Form,
  id: String,
  change: fn(Control) -> Control,
) -> Form {
  case find_control(form, id) {
    Some(control) -> update_control(form, change(control))
    None -> form
  }
}

// Removes a control together with its descendants and adoption entries.
pub fn remove_control(form: Form, id: String) -> Form {
  let ids = subtree_ids(form, id)
  Form(
    ..form,
    controls: list.filter(form.controls, fn(control) {
      !list.contains(ids, control.id)
    }),
    parents: list.filter(form.parents, fn(entry) {
      !list.contains(ids, entry.0)
    }),
  )
}

// Pasting duplicates a copied subtree (controls + parent links). The subtree
// root is adopted by `target_id` ("" = window) and positioned inside it.
pub fn paste_controls(
  form: Form,
  clipboard: List(Control),
  clipboard_parents: List(#(String, String)),
  clipboard_aligns: List(#(String, Align)),
  target_id: String,
) -> #(Form, Option(Control)) {
  case clipboard {
    [] -> #(form, None)
    [root, ..] -> {
      let base = list.length(form.controls)
      let mapping =
        list.index_map(clipboard, fn(control, index) {
          let new_id = control.id <> "-copy" <> int.to_string(base + index + 1)
          let new_name =
            control.name <> "_copy" <> int.to_string(base + index + 1)
          #(control.id, Control(..control, id: new_id, name: new_name))
        })
      let pasted_root = case
        list.find(mapping, fn(entry) { entry.0 == root.id })
      {
        Ok(entry) -> entry.1
        Error(_) -> root
      }
      let #(target_x, target_y) = paste_position(form, target_id)
      let dx = target_x - root.x
      let dy = target_y - root.y
      let pasted_controls =
        list.map(mapping, fn(entry) {
          let #(_old_id, control) = entry
          Control(..control, x: control.x + dx, y: control.y + dy)
        })
      let new_parents =
        list.map(mapping, fn(entry) {
          let #(old_id, control) = entry
          let new_parent = case old_id == root.id {
            True -> target_id
            False ->
              case old_parent(clipboard_parents, old_id) {
                "" -> target_id
                old ->
                  case list.find(mapping, fn(item) { item.0 == old }) {
                    Ok(item) -> item.1.id
                    Error(_) -> target_id
                  }
              }
          }
          #(control.id, new_parent)
        })
      let new_aligns =
        list.filter_map(mapping, fn(entry) {
          let #(old_id, control) = entry
          case list.find(clipboard_aligns, fn(align) { align.0 == old_id }) {
            Ok(align) -> Ok(#(control.id, align.1))
            Error(_) -> Error(Nil)
          }
        })
      let next =
        Form(
          ..form,
          controls: list.append(form.controls, pasted_controls),
          parents: list.append(form.parents, new_parents),
          aligns: list.append(form.aligns, new_aligns),
        )
      #(next, find_new(next, pasted_root.id))
    }
  }
}

fn old_parent(parents: List(#(String, String)), id: String) -> String {
  case list.find(parents, fn(entry) { entry.0 == id }) {
    Ok(entry) -> entry.1
    Error(_) -> ""
  }
}

fn find_new(form: Form, id: String) -> Option(Control) {
  find_control(form, id)
}

fn paste_position(form: Form, target_id: String) -> #(Int, Int) {
  case target_id {
    "" -> #(24, 24)
    _ ->
      case find_control(form, target_id) {
        Some(parent) -> {
          let index = list.length(children_of(form, target_id))
          #(parent.x + 12, parent.y + 36 + index * 36)
        }
        None -> #(24, 24)
      }
  }
}

// The handler a control owns, following the Delphi naming convention of
// <name>_<event>. Derived, never stored, so renames stay consistent.
pub fn handler_name(control: Control) -> Option(String) {
  case campy_ccl.find(kind_key(control.kind)) {
    Some(campy_ccl.Component(event: Some(event), ..)) ->
      Some(control.name <> "_" <> event.key)
    _ -> None
  }
}

pub fn event_label(kind: Kind) -> String {
  case campy_ccl.find(kind_key(kind)) {
    Some(campy_ccl.Component(event: Some(event), ..)) -> event.label
    _ -> ""
  }
}

pub fn event_key(kind: Kind) -> String {
  case campy_ccl.find(kind_key(kind)) {
    Some(campy_ccl.Component(event: Some(event), ..)) -> event.key
    _ -> ""
  }
}

pub fn valid_name(name: String) -> Bool {
  let tail = "abcdefghijklmnopqrstuvwxyz_0123456789"
  case string.to_graphemes(name) {
    [] -> False
    [first, ..rest] ->
      string.contains("abcdefghijklmnopqrstuvwxyz_", first)
      && list.all(rest, fn(char) { string.contains(tail, char) })
  }
}

pub fn validate(form: Form) -> Result(Form, String) {
  case
    form.width > 0
    && form.height > 0
    && form.width <= 4096
    && form.height <= 4096
  {
    False -> Error("Form size must be between 1 and 4096 pixels")
    True -> {
      let names = list.map(form.controls, fn(control) { control.name })
      let ids = list.map(form.controls, fn(control) { control.id })
      case list.all(names, valid_name) {
        False -> Error("Control names must be valid Gleam identifiers")
        True ->
          case list.length(names) == list.length(list.unique(names)) {
            False -> Error("Control names must be unique")
            True ->
              case list.length(ids) == list.length(list.unique(ids)) {
                False -> Error("Control IDs must be unique")
                True -> Ok(form)
              }
          }
      }
    }
  }
}

pub fn default_source() -> String {
  "// Campy event handlers.\n\n// Select an event in the Inspector to create a handler here.\n"
}

// Returns the source plus the 0-based line where the handler starts.
pub fn ensure_handler(source: String, handler: String) -> #(String, Int) {
  case find_handler_line(source, handler) {
    Some(index) -> #(source, index)
    None -> {
      let base = trim_newlines(source)
      let stub =
        "pub fn "
        <> handler
        <> "() -> Nil {\n  // TODO: implement "
        <> handler
        <> ".\n  Nil\n}"
      let index = list.length(string.split(base, "\n")) + 1
      #(base <> "\n\n" <> stub <> "\n", index)
    }
  }
}

fn trim_newlines(input: String) -> String {
  case string.ends_with(input, "\n") {
    True -> trim_newlines(string.drop_end(input, 1))
    False -> input
  }
}

pub fn find_handler_line(source: String, handler: String) -> Option(Int) {
  let needle = "pub fn " <> handler <> "()"
  source
  |> string.split("\n")
  |> list.index_map(fn(line, index) {
    case string.starts_with(string.trim(line), needle) {
      True -> Some(index)
      False -> None
    }
  })
  |> first_some
}

pub fn handler_range(source: String, start: Int) -> Option(#(Int, Int)) {
  source
  |> string.split("\n")
  |> list.drop(start)
  |> list.index_map(fn(line, offset) {
    case string.trim(line) == "}" {
      True -> Some(start + offset)
      False -> None
    }
  })
  |> first_some
  |> option_map(fn(end) { #(start, end) })
}

pub fn handler_text(source: String, range: #(Int, Int)) -> String {
  let #(start, end) = range
  source
  |> string.split("\n")
  |> list.drop(start)
  |> list.take(end - start + 1)
  |> string.join("\n")
}

// Replaces one handler block and returns the new source plus its new range.
pub fn replace_handler(
  source: String,
  range: #(Int, Int),
  text: String,
) -> #(String, #(Int, Int)) {
  let #(start, end) = range
  let lines = string.split(source, "\n")
  let block = string.split(trim_newlines(text), "\n")
  let next =
    list.append(
      list.append(list.take(lines, start), block),
      list.drop(lines, end + 1),
    )
  #(string.join(next, "\n"), #(start, start + list.length(block) - 1))
}

fn first_some(options: List(Option(a))) -> Option(a) {
  case options {
    [] -> None
    [Some(value), ..] -> Some(value)
    [None, ..rest] -> first_some(rest)
  }
}

fn option_map(option: Option(a), fun: fn(a) -> b) -> Option(b) {
  case option {
    Some(value) -> Some(fun(value))
    None -> None
  }
}
