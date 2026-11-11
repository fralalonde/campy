import campy_bridge
import campy_runtime as runtime
import campy_search_box as search_box
import campy_ui
import gleam/int
import gleam/io
import gleam/result

@external(erlang, "campy_host_ffi", "watch_enabled")
fn watch_enabled() -> Bool

@external(erlang, "campy_host_ffi", "signal")
fn signal() -> String

@external(erlang, "campy_host_ffi", "wait")
fn wait() -> Nil

@external(erlang, "campy_host_ffi", "reload_search_box")
fn reload_search_box() -> Result(Nil, String)

@external(erlang, "campy_host_ffi", "describe_search_box")
fn describe_search_box() -> Result(campy_ui.Definition, String)

pub fn main() {
  let assert 1 = campy_bridge.protocol_version()
  let assert Ok(definition) = describe_search_box()
  let assert Ok(source) = campy_ui.to_slint(definition)
  let assert Ok(_) = campy_bridge.validate_ui(source)
  let assert Ok(session) = runtime.new(definition)
  io.println("Campy bootstrap: Gleam → in-process Rust NIF → Slint compiler OK")
  io.println("UI generation 1 accepted (headless compiler mode).")
  case watch_enabled() {
    True -> {
      io.println("Watching search-box builds; Ctrl-C stops the host.")
      loop(session, search_box.init(), signal())
    }
    False -> Nil
  }
}

fn loop(session: runtime.Session, model: search_box.Model, previous: String) {
  wait()
  let current = signal()
  case current == previous {
    True -> loop(session, model, previous)
    False -> {
      case reload(session) {
        Ok(next) -> {
          io.println(
            "Accepted UI generation "
            <> int.to_string(runtime.generation(next))
            <> "; model retained, query="
            <> model.query,
          )
          loop(next, model, current)
        }
        Error(error) -> {
          io.println("Reload rejected; keeping last accepted UI: " <> error)
          loop(session, model, current)
        }
      }
    }
  }
}

fn reload(session: runtime.Session) -> Result(runtime.Session, String) {
  use _ <- result.try(reload_search_box())
  use candidate <- result.try(describe_search_box())
  use source <- result.try(campy_ui.to_slint(candidate))
  use _ <- result.try(campy_bridge.validate_ui(source))
  runtime.commit(session, candidate)
}
