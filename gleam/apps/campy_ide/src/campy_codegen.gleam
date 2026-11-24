import campy_search_box
import campy_ui
import gleam/io

// Writes the search box's generated description (`just generate`). Protocol v2
// has no interpreter or per-load compile, so this stays a definition-level
// artifact until the packaging/docs wave retires it.

@external(erlang, "campy_host_ffi", "write_generated")
fn write_generated(source: String) -> Result(Nil, String)

pub fn main() {
  let assert Ok(source) =
    campy_ui.to_application_slint(campy_search_box.describe())
  let assert Ok(_) = write_generated(source)
  io.println("Generated and validated generated/search_box.slint")
}
