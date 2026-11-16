// Notes handlers (ABI v2 shape; the runtime lands in M3).

pub type State {
  State(text: String)
}

pub fn init() -> State {
  State(text: "")
}
