import campy_bridge
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn loads_the_real_native_library_test() {
  campy_bridge.protocol_version() |> should.equal(1)
}

pub fn validates_ui_in_the_running_beam_vm_test() {
  campy_bridge.validate_ui("export component Test inherits Window {}")
  |> should.equal(Ok(1))
}

pub fn invalid_ui_returns_a_typed_error_test() {
  campy_bridge.validate_ui("this is not Slint") |> should.be_error
}
