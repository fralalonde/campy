// Handlers for the pure FFI tests. This module is referenced by name through
// campy_app's dynamic dispatch, exactly like a generated handlers module.

pub fn pet_button_clicked() -> Nil {
  Nil
}

pub fn break_button_clicked() -> Nil {
  panic as "boom"
}

pub fn long_button_clicked() -> Nil {
  panic as "this reason is deliberately long enough to be truncated by the app runtime before it reaches a report; it keeps going and going and going and going and going and going and going and going and going and going and going past one hundred and eighty characters"
}
