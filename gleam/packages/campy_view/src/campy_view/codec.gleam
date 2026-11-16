//// Canonical JSON for view documents (ADR 0005).
////
//// Encoding is fully deterministic: fixed field order, sorted object keys,
//// two-space indent, LF, one trailing newline, UTF-8 preserved. Decoding uses
//// OTP's `json` module and validates structure; unknown node fields are
//// preserved in `Node.extra` so an older reader cannot destroy newer data.
////
//// A document is `{"schema": <int>, "view": <node>, ...extra}`. Schema policy
//// belongs to the caller: a newer schema is decoded, not refused here.

import campy_view.{
  type Document, type Node, type Value, VBool, VFloat, VInt, VList, VMap, VNull,
  VText, normalize, reserved_fields, validate,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Json {
  JObject(List(#(String, Json)))
  JArray(List(Json))
  JString(String)
  JInt(Int)
  JFloat(Float)
  JBool(Bool)
  JNull
}

@external(erlang, "campy_view_ffi", "decode")
fn decode_json(input: String) -> Result(Json, String)

pub fn encode(node: Node) -> String {
  node |> normalize |> node_to_json |> write
}

pub fn decode(input: String) -> Result(Node, String) {
  use json <- result.try(decode_json(input))
  use node <- result.try(node_from_json(json, "$"))

  case validate(node) {
    Ok(Nil) -> Ok(normalize(node))
    Error(message) -> Error("$: " <> message)
  }
}

pub fn encode_document(document: Document) -> String {
  let extra =
    document.extra
    |> sort_fields(["schema", "view"])
    |> list.map(fn(field) { #(field.0, value_to_json(field.1)) })

  JObject(list.append(
    [
      #("schema", JInt(document.schema)),
      #("view", node_to_json(normalize(document.view))),
    ],
    extra,
  ))
  |> write
}

pub fn decode_document(input: String) -> Result(Document, String) {
  use json <- result.try(decode_json(input))

  case json {
    JObject(fields) -> {
      use schema_json <- result.try(require_field(fields, "schema", "$"))
      use schema <- result.try(int_from_json(schema_json, "$.schema"))
      use view_json <- result.try(require_field(fields, "view", "$"))
      use view <- result.try(node_from_json(view_json, "$.view"))
      use extra <- result.try(extra_from_fields(fields, ["schema", "view"], "$"))

      case validate(view) {
        Ok(Nil) ->
          Ok(campy_view.Document(
            schema: schema,
            view: normalize(view),
            extra: extra,
          ))
        Error(message) -> Error("$.view: " <> message)
      }
    }
    _ -> Error("$: expected an object")
  }
}

fn node_to_json(node: Node) -> Json {
  let base = [#("kind", JString(node.kind)), #("id", JString(node.id))]

  let base = case node.key {
    Some(key) -> list.append(base, [#("key", JString(key))])
    None -> base
  }

  let base =
    list.append(base, [
      #(
        "props",
        JObject(
          list.map(node.props, fn(field) { #(field.0, value_to_json(field.1)) }),
        ),
      ),
    ])

  let base = case node.events {
    [] -> base
    events ->
      list.append(base, [#("events", JArray(list.map(events, JString)))])
  }

  let base = case node.children {
    [] -> base
    children ->
      list.append(base, [
        #("children", JArray(list.map(children, node_to_json))),
      ])
  }

  JObject(list.append(
    base,
    list.map(node.extra, fn(field) { #(field.0, value_to_json(field.1)) }),
  ))
}

fn value_to_json(value: Value) -> Json {
  case value {
    VText(text) -> JString(text)
    VBool(flag) -> JBool(flag)
    VInt(number) -> JInt(number)
    VFloat(number) -> JFloat(number)
    VNull -> JNull
    VList(items) -> JArray(list.map(items, value_to_json))
    VMap(fields) ->
      JObject(
        fields
        |> sort_pairs
        |> list.map(fn(field) { #(field.0, value_to_json(field.1)) }),
      )
  }
}

fn node_from_json(json: Json, path: String) -> Result(Node, String) {
  case json {
    JObject(fields) -> {
      use kind <- result.try(require_string(fields, "kind", path))
      use id <- result.try(require_string(fields, "id", path))
      use key <- result.try(key_from_fields(fields, path))
      use props <- result.try(props_from_fields(fields, path))
      use events <- result.try(events_from_fields(fields, path))
      use children <- result.try(children_from_fields(fields, path))
      use extra <- result.try(extra_from_fields(fields, reserved_fields(), path))

      Ok(campy_view.Node(
        kind: kind,
        id: id,
        key: key,
        props: props,
        events: events,
        children: children,
        extra: extra,
      ))
    }
    _ -> Error(path <> ": expected an object")
  }
}

fn value_from_json(json: Json, path: String) -> Result(Value, String) {
  case json {
    JString(text) -> Ok(VText(text))
    JBool(flag) -> Ok(VBool(flag))
    JInt(number) -> Ok(VInt(number))
    JFloat(number) -> Ok(VFloat(number))
    JNull -> Ok(VNull)
    JArray(items) ->
      items
      |> list.index_map(fn(item, index) {
        value_from_json(item, path <> "[" <> int.to_string(index) <> "]")
      })
      |> result.all
      |> result.map(VList)
    JObject(fields) ->
      fields
      |> list.try_map(fn(field) {
        value_from_json(field.1, path <> "." <> field.0)
        |> result.map(fn(value) { #(field.0, value) })
      })
      |> result.map(fn(fields) { VMap(sort_pairs(fields)) })
  }
}

fn require_field(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(Json, String) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error(path <> ": missing \"" <> name <> "\"")
  }
}

fn optional_field(fields: List(#(String, Json)), name: String) -> Option(Json) {
  case list.find(fields, fn(field) { field.0 == name }) {
    Ok(#(_, value)) -> Some(value)
    Error(Nil) -> None
  }
}

fn require_string(
  fields: List(#(String, Json)),
  name: String,
  path: String,
) -> Result(String, String) {
  use value <- result.try(require_field(fields, name, path))
  string_from_json(value, path <> "." <> name)
}

fn string_from_json(json: Json, path: String) -> Result(String, String) {
  case json {
    JString(text) -> Ok(text)
    _ -> Error(path <> ": expected a string")
  }
}

fn int_from_json(json: Json, path: String) -> Result(Int, String) {
  case json {
    JInt(number) -> Ok(number)
    _ -> Error(path <> ": expected an integer")
  }
}

fn key_from_fields(
  fields: List(#(String, Json)),
  path: String,
) -> Result(Option(String), String) {
  case optional_field(fields, "key") {
    None -> Ok(None)
    Some(JString(key)) -> Ok(Some(key))
    Some(JNull) -> Ok(None)
    Some(_) -> Error(path <> ".key: expected a string")
  }
}

fn props_from_fields(
  fields: List(#(String, Json)),
  path: String,
) -> Result(List(#(String, Value)), String) {
  case optional_field(fields, "props") {
    None -> Ok([])
    Some(JObject(props)) ->
      props
      |> list.try_map(fn(field) {
        value_from_json(field.1, path <> ".props." <> field.0)
        |> result.map(fn(value) { #(field.0, value) })
      })
    Some(_) -> Error(path <> ".props: expected an object")
  }
}

fn events_from_fields(
  fields: List(#(String, Json)),
  path: String,
) -> Result(List(String), String) {
  case optional_field(fields, "events") {
    None -> Ok([])
    Some(JArray(events)) ->
      events
      |> list.index_map(fn(item, index) {
        string_from_json(
          item,
          path <> ".events[" <> int.to_string(index) <> "]",
        )
      })
      |> result.all
    Some(_) -> Error(path <> ".events: expected an array of strings")
  }
}

fn children_from_fields(
  fields: List(#(String, Json)),
  path: String,
) -> Result(List(Node), String) {
  case optional_field(fields, "children") {
    None -> Ok([])
    Some(JArray(children)) ->
      children
      |> list.index_map(fn(child, index) {
        node_from_json(
          child,
          path <> ".children[" <> int.to_string(index) <> "]",
        )
      })
      |> result.all
    Some(_) -> Error(path <> ".children: expected an array")
  }
}

fn extra_from_fields(
  fields: List(#(String, Json)),
  reserved: List(String),
  path: String,
) -> Result(List(#(String, Value)), String) {
  fields
  |> list.filter(fn(field) { !list.contains(reserved, field.0) })
  |> list.try_map(fn(field) {
    value_from_json(field.1, path <> "." <> field.0)
    |> result.map(fn(value) { #(field.0, value) })
  })
  |> result.map(sort_pairs)
}

fn sort_pairs(fields: List(#(String, v))) -> List(#(String, v)) {
  fields
  |> dict.from_list
  |> dict.to_list
  |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
}

fn sort_fields(
  fields: List(#(String, Value)),
  reserved: List(String),
) -> List(#(String, Value)) {
  fields
  |> list.filter(fn(field) { !list.contains(reserved, field.0) })
  |> sort_pairs
}

fn write(json: Json) -> String {
  write_at(json, 0) <> "\n"
}

fn write_at(json: Json, depth: Int) -> String {
  case json {
    JObject([]) -> "{}"
    JObject(fields) ->
      "{\n"
      <> string.join(
        list.map(fields, fn(field) {
          indent(depth + 1)
          <> quote(field.0)
          <> ": "
          <> write_at(field.1, depth + 1)
        }),
        ",\n",
      )
      <> "\n"
      <> indent(depth)
      <> "}"
    JArray([]) -> "[]"
    JArray(items) ->
      "[\n"
      <> string.join(
        list.map(items, fn(item) {
          indent(depth + 1) <> write_at(item, depth + 1)
        }),
        ",\n",
      )
      <> "\n"
      <> indent(depth)
      <> "]"
    JString(text) -> quote(text)
    JInt(number) -> int.to_string(number)
    JFloat(number) -> float_to_json(number)
    JBool(True) -> "true"
    JBool(False) -> "false"
    JNull -> "null"
  }
}

fn indent(depth: Int) -> String {
  string.repeat("  ", depth)
}

fn float_to_json(value: Float) -> String {
  let text = float.to_string(value)

  case
    string.contains(text, "."),
    string.contains(text, "e"),
    string.contains(text, "E")
  {
    False, False, False -> text <> ".0"
    _, _, _ -> text
  }
}

fn quote(value: String) -> String {
  let escaped =
    value
    |> string.to_utf_codepoints
    |> list.map(escape)
    |> string.concat

  "\"" <> escaped <> "\""
}

fn escape(codepoint: UtfCodepoint) -> String {
  case string.utf_codepoint_to_int(codepoint) {
    0x22 -> "\\\""
    0x5C -> "\\\\"
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    0x08 -> "\\b"
    0x0C -> "\\f"
    code if code < 0x20 -> "\\u00" <> hex_byte(code)
    _ -> string.from_utf_codepoints([codepoint])
  }
}

fn hex_byte(code: Int) -> String {
  let digits = case int.to_base_string(code, 16) {
    Ok(text) -> text
    Error(Nil) -> "0"
  }
  case string.length(digits) {
    1 -> "0" <> digits
    _ -> digits
  }
}
