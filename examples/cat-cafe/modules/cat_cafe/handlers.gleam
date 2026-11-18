//// Cat Café handlers (ABI v2: `(state, event) -> #(State, List(Effect))`).
////
//// Mochi the cat waits for snacks and pets. Feeding and petting publish
//// live UI updates through SetProp: the running app's label text and the
//// happiness bar change without any code reload.

import campy_app.{type Effect, type Event, Log, Notify, SetProp}
import campy_view.{VInt, VText}

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
    SetProp(
      "visits",
      "text",
      VText("Served " <> int_text(state.snacks) <> " snacks"),
    ),
    SetProp("happiness", "value", VInt(snack_happiness(state))),
    SetProp("status", "text", VText("Mochi is eating.")),
    Log("served snack " <> int_text(state.snacks)),
    Notify("Mochi enjoyed the snack!"),
  ])
}

/// The Pet button: petting counts too, but the cat gets bored.
pub fn pet_click(state: State, _event: Event) -> #(State, List(Effect)) {
  let state = State(..state, pets: state.pets + 1)
  #(state, [
    SetProp(
      "status",
      "text",
      VText(case state.pets {
        1 -> "Mochi purred."
        _ -> "Mochi is getting sleepy from all the petting."
      }),
    ),
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
  #(state, [
    SetProp("status", "text", VText(guest <> " is visiting.")),
    Log("guest is now " <> guest),
  ])
}

fn snack_happiness(state: State) -> Int {
  int.min(20 * state.snacks, 100)
}

fn int_text(value: Int) -> String {
  case value {
    1 -> "one"
    2 -> "two"
    _ -> "many"
  }
}
