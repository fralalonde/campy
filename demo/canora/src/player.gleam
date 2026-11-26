// Canora · now playing — transport, queue and favourites.

import gleam/int
import gleam/io
import gleam/list

const repeat_key = "canora.player.repeat"

const shuffle_key = "canora.player.shuffle"

@external(erlang, "persistent_term", "get")
fn flag(key: String, default: Bool) -> Bool

@external(erlang, "persistent_term", "put")
fn set_flag(key: String, value: Bool) -> Nil

@external(erlang, "persistent_term", "get")
fn favourites(default: List(String)) -> List(String)

pub fn play_clicked() -> Nil {
  io.println("Canora: toggle playback")
}

pub fn next_clicked() -> Nil {
  io.println("Canora: next")
}

pub fn prev_clicked() -> Nil {
  io.println("Canora: previous")
}

pub fn shuffle_clicked() -> Nil {
  let next = !flag(shuffle_key, False)
  set_flag(shuffle_key, next)
  io.println(case next {
    True -> "Canora: shuffle on"
    False -> "Canora: shuffle off"
  })
}

pub fn repeat_clicked() -> Nil {
  let next = !flag(repeat_key, False)
  set_flag(repeat_key, next)
  io.println(case next {
    True -> "Canora: repeat one"
    False -> "Canora: repeat off"
  })
}

pub fn heart_clicked() -> Nil {
  io.println(
    "Canora: " <> int.to_string(list.length(favourites([]))) <> " favourites",
  )
}

pub fn queue_selected(which: String) -> Nil {
  io.println("Canora: jump to " <> which)
}

pub fn queue_api_loaded(count: Int) -> Nil {
  io.println("Canora: " <> int.to_string(count) <> " tracks queued")
}
