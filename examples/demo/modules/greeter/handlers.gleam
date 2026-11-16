// Greeter handlers (ABI v2 shape; the runtime lands in M3).

pub type State {
  State(greetings: Int)
}

pub fn init() -> State {
  State(greetings: 0)
}

pub fn greet_clicked(state: State) -> State {
  State(greetings: state.greetings + 1)
}
