//// Greeter handlers (ABI v2: `(state, event) -> #(State, List(Effect))`).

import campy_app.{type Effect, type Event, Log, Notify}

pub type State {
  State(greetings: Int)
}

pub fn init() -> State {
  State(greetings: 0)
}

/// `<button>_click` on the greeter's Run button; the event value is ignored.
pub fn greet_click(state: State, _event: Event) -> #(State, List(Effect)) {
  let state = State(state.greetings + 1)
  #(state, [
    Log("greeted " <> count_text(state.greetings) <> " times"),
    Notify("Hello from Campy!"),
  ])
}

/// Events the designer has not wired yet stay silent.
pub fn name_change(state: State, _event: Event) -> #(State, List(Effect)) {
  #(state, [])
}

fn count_text(value: Int) -> String {
  case value {
    0 -> "0"
    1 -> "1"
    _ -> "several"
  }
}

