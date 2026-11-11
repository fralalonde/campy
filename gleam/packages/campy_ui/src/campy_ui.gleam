import campy_ui/application
import gleam/list
import gleam/result
import gleam/string

// The first schema deliberately supports only the search-box contract.
// All visual structure is data. Neither the renderer nor the designer owns it.
pub type Definition {
  Definition(id: String, title: String, body: Node)
}

pub type TextBinding {
  TextLiteral(String)
  Query
}

pub type BoolBinding {
  BoolLiteral(Bool)
  Busy
  Not(BoolBinding)
}

pub type Node {
  Row(id: String, children: List(Node))
  TextField(id: String, value: TextBinding)
  Button(id: String, text: TextBinding, enabled: BoolBinding)
}

pub fn validate(definition: Definition) -> Result(Definition, String) {
  let ids = node_ids(definition.body)
  case
    list.all(ids, valid_identifier),
    list.length(ids) == list.length(list.unique(ids))
  {
    False, _ ->
      Error(
        "Node IDs must start with a lowercase letter and contain only a-z, 0-9, or hyphens",
      )
    _, False -> Error("Node IDs must be unique within a component")
    True, True -> Ok(definition)
  }
}

pub fn to_slint(definition: Definition) -> Result(String, String) {
  emit(definition, False)
}

pub fn to_application_slint(definition: Definition) -> Result(String, String) {
  emit(definition, True)
}

fn emit(definition: Definition, with_menu: Bool) -> Result(String, String) {
  use definition <- result.try(validate(definition))
  let imports = case with_menu {
    True -> application.imports()
    False -> ""
  }
  let content = render_node(definition.body)
  let body = case with_menu {
    True -> application.render(content)
    False -> content
  }
  let height = case with_menu {
    True -> "156px"
    False -> "100px"
  }
  Ok(
    imports
    <> "import { Button, LineEdit } from \"std-widgets.slint\";\n"
    <> "export component CampyPreview inherits Window {\n"
    <> "  title: "
    <> quote(definition.title)
    <> ";\n"
    <> "  width: 480px; height: "
    <> height
    <> ";\n"
    <> "  in-out property <string> query;\n"
    <> "  in property <bool> busy: false;\n"
    <> "  callback query-changed(string);\n"
    <> "  callback search();\n"
    <> body
    <> "\n}\n",
  )
}

fn render_node(node: Node) -> String {
  case node {
    Row(id, children) ->
      id
      <> " := HorizontalLayout { spacing: 8px; padding: 12px;\n"
      <> string.join(list.map(children, render_node), "\n")
      <> "\n}"
    TextField(id, Query) ->
      id
      <> " := LineEdit { text <=> root.query; "
      <> "edited => { root.query-changed(self.text); } }"
    TextField(id, value) ->
      id
      <> " := LineEdit { text: "
      <> render_text(value)
      <> "; edited => { root.query-changed(self.text); } }"
    Button(id, text, enabled) ->
      id
      <> " := Button { text: "
      <> render_text(text)
      <> "; enabled: "
      <> render_bool(enabled)
      <> "; clicked => { root.search(); } }"
  }
}

fn render_text(value: TextBinding) -> String {
  case value {
    TextLiteral(text) -> quote(text)
    Query -> "root.query"
  }
}

fn render_bool(value: BoolBinding) -> String {
  case value {
    BoolLiteral(True) -> "true"
    BoolLiteral(False) -> "false"
    Busy -> "root.busy"
    Not(inner) -> "!(" <> render_bool(inner) <> ")"
  }
}

fn quote(value: String) -> String {
  let escaped =
    value
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}

fn node_ids(node: Node) -> List(String) {
  case node {
    Row(id, children) -> [id, ..list.flat_map(children, node_ids)]
    TextField(id, _) -> [id]
    Button(id, _, _) -> [id]
  }
}

fn valid_identifier(id: String) -> Bool {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  case string.to_graphemes(id) {
    [] -> False
    [first, ..rest] ->
      string.contains(letters, first)
      && list.all(rest, fn(char) {
        string.contains(letters <> "0123456789-", char)
      })
  }
}
