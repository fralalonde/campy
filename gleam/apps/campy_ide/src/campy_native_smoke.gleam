import campy_search_box
import campy_ui

@external(erlang, "campy_native_smoke_ffi", "run")
fn run(source: String, application_source: String) -> Nil

pub fn main() {
  let assert Ok(source) = campy_ui.to_slint(campy_search_box.describe())
  let assert Ok(application_source) =
    campy_ui.to_application_slint(campy_search_box.describe())
  run(source, application_source)
}
