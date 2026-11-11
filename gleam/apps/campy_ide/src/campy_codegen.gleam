import campy_bridge
import campy_search_box
import campy_ui
import gleam/io

@external(erlang, "campy_host_ffi", "write_generated")
fn write_generated(source: String) -> Result(Nil, String)

pub fn main() {
  let assert Ok(source) =
    campy_ui.to_application_slint(campy_search_box.describe())
  let assert Ok(_) = campy_bridge.validate_ui(source)
  let assert Ok(_) = write_generated(source)
  io.println("Generated and validated generated/search_box.slint")
}
