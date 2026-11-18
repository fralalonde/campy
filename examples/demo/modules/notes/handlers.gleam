//// Notes handlers (ABI v2: `(state, event) -> #(State, List(Effect))`).

import campy_app.{type Effect, type Event, Log}
import campy_view.VText

pub type State {
  State(text: String)
}

pub fn init() -> State {
  State(text: "")
}

/// `<memo>_change` carries the memo's text as the event value.
pub fn body_change(state: State, event: Event) -> #(State, List(Effect)) {
  case event.value {
    VText(text) -> #(State(text: text), [Log("note updated")])
    _ -> #(state, [])
  }
}
