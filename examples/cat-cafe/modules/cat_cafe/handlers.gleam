//// Cat Café handlers (ABI v2: `(state, event) -> #(State, List(Effect))`).
////
//// Mochi the cat waits for snacks and pets. The name field decides who
//// is being served; the progress bar shows how happy the cat is.

import campy_app.{type Effect, type Event, Log, Notify}
import campy_view.{VText}

pub type State {
  State(snacks: Int, pets: Int)
}

pub fn init() -> State {
  State(snacks: 0, pets: 0)
}

/// The Feed button: a snack makes the cat happier.
pub fn feed_click(state: State, _event: Event) -> #(State, List(Effect)) {
  let state = State(..state, snacks: state.snacks + 1)
  #(state, [
    Log("served snack number " <> int_text(state.snacks)),
    Notify("Mochi enjoyed the snack!"),
  ])
}

/// The Pet button: petting counts too.
pub fn pet_click(state: State, _event: Event) -> #(State, List(Effect)) {
  let state = State(..state, pets: state.pets + 1)
  #(state, [
    Log("petted " <> int_text(state.pets) <> " time(s)"),
    Notify("Mochi purred."),
  ])
}

/// Renaming the café guest.
pub fn name_change(state: State, event: Event) -> #(State, List(Effect)) {
  let guest = case event.value {
    VText(text) -> text
    _ -> "(unnamed)"
  }
  #(state, [Log("guest is now " <> guest)])
}

fn int_text(value: Int) -> String {
  case value {
    1 -> "one"
    2 -> "two"
    _ -> "many"
  }
}
