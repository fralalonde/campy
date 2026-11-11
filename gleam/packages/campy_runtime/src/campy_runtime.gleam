import campy_ui
import gleam/result

pub opaque type Session {
  Session(definition: campy_ui.Definition, generation: Int)
}

pub fn new(definition: campy_ui.Definition) -> Result(Session, String) {
  use definition <- result.try(campy_ui.validate(definition))
  Ok(Session(definition, 1))
}

// Call only after native compilation succeeds. Failure leaves the caller's
// immutable session untouched. A full code/UI/effect transaction is M3 work.
pub fn commit(
  session: Session,
  candidate: campy_ui.Definition,
) -> Result(Session, String) {
  use candidate <- result.try(campy_ui.validate(candidate))
  case candidate.id == session.definition.id {
    True -> Ok(Session(candidate, session.generation + 1))
    False -> Error("Reload cannot change the component identity")
  }
}

pub fn generation(session: Session) -> Int {
  session.generation
}

pub fn accepts_event(session: Session, event_generation: Int) -> Bool {
  session.generation == event_generation
}
