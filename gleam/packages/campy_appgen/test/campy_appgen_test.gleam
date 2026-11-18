//// Appgen tests: the generated module must carry the embedded view, the
//// verbatim handlers, hoisted imports, and stubs for missing handlers.

import campy_appgen
import campy_view.{VInt, VText}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn document(children: List(campy_view.Node)) -> campy_view.Document {
  campy_view.Document(
    schema: 1,
    view: campy_view.node("form", "root")
      |> campy_view.with_props([#("w", VInt(400))])
      |> campy_view.with_children(children),
    extra: [],
  )
}

fn button(id: String, events: List(String)) -> campy_view.Node {
  campy_view.node("button", id)
  |> campy_view.with_props([#("text", VText(id))])
  |> campy_view.with_events(events)
}

const handlers =
  "
import gleam/int

pub type State {
  State(count: Int)
}

pub fn init() -> State {
  State(0)
}

pub fn ok_click(state: State, _event: Event) -> #(State, List(Effect)) {
  #(state, [])
}
"

fn generate(children: List(campy_view.Node), handlers: String) -> String {
  let assert Ok(source) =
    campy_appgen.generate("greeter", document(children), handlers)
  source
}

pub fn module_name_uses_the_slug_test() {
  campy_appgen.module_name("greeter") |> should.equal("campy_app_greeter")
}

pub fn generated_module_embeds_the_form_and_handlers_test() {
  let source = generate([button("ok", ["click"])], handlers)

  string.contains(source, "campy_app_greeter")
  |> should.equal(False)
  // The embedded view construction is present...
  string.contains(source, "pub fn view(_state: State) -> Document")
  |> should.equal(True)
  string.contains(source, "campy_view.node(\"form\", \"root\")")
  |> should.equal(True)
  string.contains(source, "campy_view.node(\"button\", \"ok\")")
  |> should.equal(True)
  // ...as are the verbatim handlers and the hoisted import.
  string.contains(source, "pub fn ok_click(state: State, _event: Event)")
  |> should.equal(True)
  string.contains(source, "import gleam/int")
  |> should.equal(True)
  // Only one view/1 exists (the generated one).
  count_occurrences(source, "pub fn view(") |> should.equal(1)
}

pub fn generated_imports_the_runtime_contracts_test() {
  let source = generate([button("ok", ["click"])], handlers)

  string.contains(source, "import campy_app.{type Event, type Effect}")
  |> should.equal(True)
  string.contains(source, "import campy_view.{type Document")
  |> should.equal(True)
  // The user's own campy_* imports are dropped (already imported).
  count_occurrences(source, "import campy_")
  |> should.equal(2)
}

pub fn missing_events_get_abi_v2_stubs_test() {
  // The handlers implement ok_click but not paint; both are declared.
  let source = generate([button("ok", ["click", "paint"])], handlers)

  count_occurrences(source, "pub fn ok_click(") |> should.equal(1)
  string.contains(
    source,
    "pub fn ok_paint(state: State, event: Event) -> #(State, List(Effect))",
  )
  |> should.equal(True)
}

pub fn nested_events_get_stubs_too_test() {
  let panel =
    campy_view.node("panel", "panel")
    |> campy_view.with_child(button("inside", ["click"]))

  let source = generate([panel], handlers)

  string.contains(source, "pub fn inside_click(state: State, event: Event)")
  |> should.equal(True)
}

pub fn handlers_defining_view_are_rejected_test() {
  campy_appgen.generate(
    "greeter",
    document([]),
    handlers <> "\npub fn view(s: State) -> Int { 1 }",
  )
  |> should.equal(Error(
    "appgen: handlers must not define view/1; it is generated",
  ))
}

pub fn handlers_without_state_are_rejected_test() {
  campy_appgen.generate("greeter", document([]), "pub fn init() -> Int { 0 }")
  |> should.equal(Error("appgen: handlers must define `pub type State`"))
}

pub fn handlers_without_init_are_rejected_test() {
  campy_appgen.generate("greeter", document([]), "pub type State { State }")
  |> should.equal(Error("appgen: handlers must define `pub fn init/0`"))
}

pub fn empty_handlers_are_rejected_test() {
  campy_appgen.generate("greeter", document([]), "  \n")
  |> should.equal(Error("appgen: handlers source is empty"))
}

pub fn invalid_slug_is_rejected_test() {
  campy_appgen.generate("Greeter!", document([]), handlers)
  |> should.equal(Error("appgen: invalid module slug: Greeter!"))
}

fn count_occurrences(haystack: String, needle: String) -> Int {
  haystack
  |> string.split(needle)
  |> list.length
  |> fn(count) { count - 1 }
}

pub fn handler_doc_comments_and_imports_are_handled_test() {
  let source =
    "//// Notes handlers.\n\nimport campy_app.{type Effect, type Event, Log}\nimport campy_view.VText\n\npub type State {\n  State(text: String)\n}\n\npub fn init() -> State {\n  State(\"\")\n}\n"

  let assert Ok(generated) =
    campy_appgen.generate(
      "notes",
      document([button("body", ["change"])]),
      source,
    )

  // The user doc comment is first, imports are merged exactly once, and the
  // body keeps only declarations.
  let lines = string.split(generated, "\n")
  let assert [first, ..] = lines
  first |> should.equal("//// Notes handlers.")
  count_occurrences(generated, "import campy_app.")
  |> should.equal(1)
  count_occurrences(generated, "import campy_view.")
  |> should.equal(1)
  string.contains(generated, "import campy_view.{type Document, VText}")
  |> should.equal(True)
  string.contains(generated, "pub type State {")
  |> should.equal(True)
  string.contains(generated, "import campy_view.VText")
  |> should.equal(False)
}
