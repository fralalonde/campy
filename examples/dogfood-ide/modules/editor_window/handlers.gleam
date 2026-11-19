//// Mini Campy handlers (ABI v2): the IDE that Campy itself built.
////
//// Dogfood target: open this project in Campy, press Run, and the designed
//// app is a miniature of the IDE editing it.

import campy_app.{
  type Effect, type Event, Log, Notify, SetProp,
}
import campy_view.{VText}

pub type State {
  State(file: String, opened: Int)
}

pub fn init() -> State {
  State(file: "src/campy.gleam", opened: 0)
}

/// Picking a file in the navigator loads it into the Code page.
pub fn navigator_select(state: State, event: Event) -> #(State, List(Effect)) {
  let file = case event.value {
    VText(text) -> text
    _ -> state.file
  }
  let state = State(..state, file: file, opened: state.opened + 1)
  #(state, [
    SetProp("src_view", "text", VText(file_body(file))),
    SetProp("footline", "text", VText("opened " <> file)),
    Log("navigator -> " <> file),
  ])
}

/// Typing in the code editor mirrors a line into the console status.
pub fn code_change(state: State, _event: Event) -> #(State, List(Effect)) {
  #(state, [
    Notify("code change on " <> state.file),
    SetProp("out_view", "text", VText("editing " <> state.file)),
  ])
}

fn file_body(file: String) -> String {
  "//// " <> file <> "\n//// (a designed placeholder module.)\n"
}
