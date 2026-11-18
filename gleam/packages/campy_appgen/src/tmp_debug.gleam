import campy_appgen
import campy_view.{VInt}
import gleam/io

pub fn main() {
  let source =
    "\nimport campy_app.{type Effect, type Event, Log, Notify}
pub type State {
  State(greetings: Int)
}

pub fn init() -> State {
  State(greetings: 0)
}
"
  let assert Ok(generated) =
    campy_appgen.generate(
      "greeter",
      campy_view.Document(
        schema: 1,
        view: campy_view.node("form", "root"),
        extra: [],
      ),
      source,
    )
  io.println(generated)
}
