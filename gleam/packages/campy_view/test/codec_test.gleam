import campy_view.{VFloat, VInt, VMap, VNull, VText}
import campy_view/codec
import gleam/string
import gleeunit/should

fn label(id: String, text: String) -> campy_view.Node {
  campy_view.node("label", id)
  |> campy_view.with_props([#("text", VText(text))])
}

fn error_of(result: Result(a, String)) -> String {
  let assert Error(message) = result
  message
}

pub fn canonical_shape_is_exact_test() {
  let node =
    campy_view.node("panel", "root")
    |> campy_view.with_key("k")
    |> campy_view.with_props([#("b", VInt(2)), #("a", VText("x"))])
    |> campy_view.with_events(["click"])
    |> campy_view.with_children([label("a", "A")])

  codec.encode(node)
  |> should.equal(
    "{
  \"kind\": \"panel\",
  \"id\": \"root\",
  \"key\": \"k\",
  \"props\": {
    \"a\": \"x\",
    \"b\": 2
  },
  \"events\": [
    \"click\"
  ],
  \"children\": [
    {
      \"kind\": \"label\",
      \"id\": \"a\",
      \"props\": {
        \"text\": \"A\"
      }
    }
  ]
}
",
  )
}

pub fn empty_and_optional_fields_are_omitted_test() {
  let encoded = codec.encode(label("a", "A"))

  encoded |> string.contains("\"key\"") |> should.be_false()
  encoded |> string.contains("\"events\"") |> should.be_false()
  encoded |> string.contains("\"children\"") |> should.be_false()
  encoded |> string.contains("\"props\"") |> should.be_true()
}

pub fn encode_decode_round_trip_test() {
  let node =
    campy_view.node("panel", "root")
    |> campy_view.with_events(["click"])
    |> campy_view.with_children([label("a", "A")])

  codec.decode(codec.encode(node)) |> should.equal(Ok(node))
}

pub fn canonical_input_reencodes_identically_test() {
  let canonical = codec.encode(label("a", "Café ☕"))
  codec.decode(canonical) |> should.equal(Ok(label("a", "Café ☕")))
  codec.encode(codec.decode(canonical) |> result_ok) |> should.equal(canonical)
}

fn result_ok(result: Result(a, String)) -> a {
  let assert Ok(value) = result
  value
}

pub fn unicode_quotes_and_newlines_round_trip_test() {
  let text = "Café ☕ \"quoted\"\n\tline\\two"
  let node = label("a", text)

  codec.decode(codec.encode(node)) |> should.equal(Ok(node))
}

pub fn control_characters_are_escaped_test() {
  let node = label("a", "x\u{0001}y")
  let encoded = codec.encode(node)

  encoded |> string.contains("\\u0001") |> should.be_true()
  codec.decode(encoded) |> should.equal(Ok(node))
}

pub fn integers_stay_integers_test() {
  let node =
    campy_view.node("label", "a") |> campy_view.with_props([#("v", VInt(3))])

  let encoded = codec.encode(node)
  encoded |> string.contains("\"v\": 3") |> should.be_true()
  encoded |> string.contains("3.0") |> should.be_false()
}

pub fn floats_stay_floats_test() {
  let node =
    campy_view.node("label", "a")
    |> campy_view.with_props([#("v", VFloat(1.5))])

  let encoded = codec.encode(node)
  encoded |> string.contains("\"v\": 1.5") |> should.be_true()
  codec.decode(encoded) |> should.equal(Ok(node))
}

pub fn whole_floats_do_not_become_integers_test() {
  let node =
    campy_view.node("label", "a")
    |> campy_view.with_props([#("v", VFloat(1.0))])

  let encoded = codec.encode(node)
  encoded |> string.contains("\"v\": 1.0") |> should.be_true()
  codec.decode(encoded) |> should.equal(Ok(node))
}

pub fn null_values_round_trip_test() {
  let node =
    campy_view.node("label", "a") |> campy_view.with_props([#("v", VNull)])

  let encoded = codec.encode(node)
  encoded |> string.contains("\"v\": null") |> should.be_true()
  codec.decode(encoded) |> should.equal(Ok(node))
}

pub fn unknown_node_fields_are_preserved_test() {
  let input =
    "{\"kind\":\"label\",\"id\":\"a\",\"props\":{},\"future\":{\"n\":1}}"
  let assert Ok(node) = codec.decode(input)

  node.extra
  |> should.equal([#("future", VMap([#("n", VInt(1))]))])

  let encoded = codec.encode(node)
  encoded |> string.contains("\"future\"") |> should.be_true()
  codec.decode(encoded) |> should.equal(Ok(node))
}

pub fn props_are_sorted_test() {
  let node =
    campy_view.node("label", "a")
    |> campy_view.with_props([#("z", VInt(1)), #("a", VInt(2))])

  codec.encode(node)
  |> string.contains(
    "\"props\": {
    \"a\": 2,
    \"z\": 1
  }",
  )
  |> should.be_true()
}

pub fn document_round_trips_test() {
  let document =
    campy_view.Document(schema: 1, view: label("a", "A"), extra: [])

  let encoded = codec.encode_document(document)
  encoded
  |> string.starts_with("{\n  \"schema\": 1,\n  \"view\": {")
  |> should.be_true()
  codec.decode_document(encoded) |> should.equal(Ok(document))
}

pub fn document_keeps_unknown_fields_test() {
  let input =
    "{
  \"schema\": 2,
  \"view\": {
    \"kind\": \"label\",
    \"id\": \"a\",
    \"props\": {}
  },
  \"note\": \"hi\"
}
"
  let assert Ok(document) = codec.decode_document(input)

  document.schema |> should.equal(2)
  document.extra |> should.equal([#("note", VText("hi"))])

  codec.decode_document(codec.encode_document(document))
  |> should.equal(Ok(document))
}

pub fn future_schema_is_not_refused_by_the_codec_test() {
  let input =
    "{\"schema\":99,\"view\":{\"kind\":\"label\",\"id\":\"a\",\"props\":{}}}"

  let assert Ok(document) = codec.decode_document(input)
  document.schema |> should.equal(99)
}

pub fn malformed_json_is_an_error_test() {
  codec.decode("{")
  |> error_of
  |> string.starts_with("invalid JSON")
  |> should.be_true()
}

pub fn missing_kind_reports_a_path_test() {
  codec.decode("{\"id\":\"a\"}")
  |> error_of
  |> should.equal("$: missing \"kind\"")
}

pub fn wrong_prop_type_reports_a_path_test() {
  codec.decode("{\"kind\":\"label\",\"id\":\"a\",\"props\":[]}")
  |> error_of
  |> should.equal("$.props: expected an object")
}

pub fn wrong_event_type_reports_a_path_test() {
  codec.decode("{\"kind\":\"label\",\"id\":\"a\",\"events\":[1]}")
  |> error_of
  |> should.equal("$.events[0]: expected a string")
}

pub fn nested_error_reports_the_child_path_test() {
  codec.decode(
    "{\"kind\":\"panel\",\"id\":\"root\",\"children\":[{\"kind\":\"label\"}]}",
  )
  |> error_of
  |> should.equal("$.children[0]: missing \"id\"")
}

pub fn duplicate_ids_are_rejected_test() {
  codec.decode(
    "{\"kind\":\"panel\",\"id\":\"a\",\"children\":[{\"kind\":\"label\",\"id\":\"a\",\"props\":{}}]}",
  )
  |> error_of
  |> should.equal("$: duplicate node id: a")
}

pub fn non_object_documents_are_rejected_test() {
  codec.decode("[]") |> error_of |> should.equal("$: expected an object")
}
