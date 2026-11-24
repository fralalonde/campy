//! zgui host adapter. Live zgui values never leave the dedicated UI thread.
//!
//! The renderer owns one winit event loop (started with
//! `with_any_thread(true)` so the BEAM may spawn it from a NIF), one zgui
//! application, and one OS window per bridge session. `LoadUi` turns a
//! `ControlDesc` tree into a zgui document; later commands address the
//! controls it created by id.

pub mod controls;
pub mod sheet;
pub mod sessions;
#[cfg(feature = "ui-testing")]
pub mod testing;
pub mod wire;
