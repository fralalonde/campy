// Canora · search — query the catalogue the datasource filled.

import gleam/int
import gleam/io
import gleam/string

const last_query_key = "canora.search.query"

@external(erlang, "persistent_term", "get")
fn state(key: String, default: String) -> String

@external(erlang, "persistent_term", "put")
fn remember(key: String, value: String) -> Nil

pub fn go_clicked() -> Nil {
  let query = string.trim(state(last_query_key, ""))
  case query {
    "" -> io.println("Canora: type something to search for")
    _ -> io.println("Canora: searching for \"" <> query <> "\"")
  }
}

pub fn clear_clicked() -> Nil {
  remember(last_query_key, "")
  io.println("Canora: search cleared")
}

/// A row was picked: send it to the player as the current track.
pub fn results_selected(which: String) -> Nil {
  io.println("Canora: playing " <> which)
}

pub fn results_api_loaded(count: Int) -> Nil {
  io.println("Canora: " <> int.to_string(count) <> " results")
}

pub fn hamburger_selected(which: String) -> Nil {
  case which {
    "Quit" -> io.println("Canora: bye")
    _ -> io.println("Canora: " <> which)
  }
}
