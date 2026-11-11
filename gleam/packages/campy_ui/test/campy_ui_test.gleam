import campy_ui as ui
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn rejects_duplicate_identity_test() {
  ui.Definition(
    "test",
    "Test",
    ui.Row("same", [ui.TextField("same", ui.Query)]),
  )
  |> ui.validate
  |> should.be_error
}

pub fn rejects_source_injection_in_identifiers_test() {
  ui.Definition("test", "Test", ui.TextField("bad; }", ui.Query))
  |> ui.validate
  |> should.be_error
}

pub fn escapes_quotes_and_slint_interpolation_test() {
  let assert Ok(source) =
    ui.to_slint(ui.Definition(
      "test",
      "A \"title\" \\{not-code}",
      ui.TextField("input", ui.Query),
    ))
  string.contains(source, "title: \"A \\\"title\\\" \\\\{not-code}\";")
  |> should.be_true
}
