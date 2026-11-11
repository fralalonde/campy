import campy_runtime as runtime
import campy_ui as ui
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn definition(id: String) -> ui.Definition {
  ui.Definition(id, "Test", ui.TextField("query", ui.Query))
}

pub fn rejects_events_from_previous_generation_test() {
  let assert Ok(first) = runtime.new(definition("test"))
  let assert Ok(second) = runtime.commit(first, definition("test"))
  runtime.accepts_event(second, 1) |> should.be_false
  runtime.accepts_event(second, 2) |> should.be_true
}

pub fn identity_change_does_not_replace_the_session_test() {
  let assert Ok(first) = runtime.new(definition("test"))
  runtime.commit(first, definition("other")) |> should.be_error
  runtime.generation(first) |> should.equal(1)
}
