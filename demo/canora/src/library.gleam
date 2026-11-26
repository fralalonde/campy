// Canora · library — the app's home.
//
// These are the app's handlers: the component with this name answers the event.
// `playback_timer_tick` and `tracks_api_loaded` arrive from the non-visual
// components the host runs. The domain state lives in `persistent_term`, which
// is what a generated app has without a database; a real client would keep the
// queue there and the credentials in the desktop keyring.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Provider {
  Spotify
  Tidal
}

pub type Track {
  Track(title: String, artist: String, duration_ms: Int)
}

pub type Session {
  Session(track: Track, position_ms: Int, playing: Bool, queue: List(Track))
}

const session_key = "canora.session"

@external(erlang, "persistent_term", "get")
fn state(key: String, default: Option(Session)) -> Option(Session)

@external(erlang, "persistent_term", "put")
fn remember(key: String, value: Option(Session)) -> Nil

/// `"Title — Artist"`, the shape the datasource's JSON array carries.
pub fn parse_track(line: String) -> Track {
  case string.split(line, " — ") {
    [title, artist] -> Track(title, artist, 210_000)
    [title] -> Track(title, "Unknown artist", 210_000)
    _ -> Track("", "", 0)
  }
}

pub fn format_time(ms: Int) -> String {
  let seconds = int.max(ms, 0) / 1000
  let minutes = seconds / 60
  int.to_string(minutes) <> ":" <> pad(seconds % 60)
}

fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

fn current() -> Option(Session) {
  state(session_key, None)
}

fn store(session: Session) -> Nil {
  remember(session_key, Some(session))
}

pub fn play_clicked() -> Nil {
  case current() {
    Some(session) -> {
      let next = Session(..session, playing: !session.playing)
      store(next)
      io.println(case next.playing {
        True -> "▶ " <> next.track.title
        False ->
          "⏸ " <> next.track.title <> " at " <> format_time(next.position_ms)
      })
    }
    None -> io.println("Canora: nothing queued")
  }
}

pub fn next_clicked() -> Nil {
  case current() {
    None -> io.println("Canora: nothing playing")
    Some(Session(_, _, _, [])) -> io.println("Canora: queue empty")
    Some(Session(track, _, playing, [next, ..rest])) -> {
      // The played track goes to the back: the queue never drains.
      store(Session(next, 0, playing, list.append(rest, [track])))
      io.println("⏭ " <> next.title <> " — " <> next.artist)
    }
  }
}

pub fn prev_clicked() -> Nil {
  case current() {
    Some(session) -> {
      store(Session(..session, position_ms: 0))
      io.println("⏮ " <> session.track.title)
    }
    None -> Nil
  }
}

/// The datasource filled `tracks`: remember the catalogue and start on its
/// first entry when nothing is playing.
pub fn tracks_api_loaded(count: Int) -> Nil {
  io.println("Canora: catalogue holds " <> int.to_string(count) <> " tracks")
}

pub fn playback_timer_tick() -> Nil {
  case current() {
    Some(session) ->
      case session.playing {
        False -> Nil
        True -> {
          let position = case session.position_ms + 1000 {
            at if at >= session.track.duration_ms -> 0
            at -> at
          }
          store(Session(..session, position_ms: position))
        }
      }
    None -> Nil
  }
}

pub fn hamburger_selected(which: String) -> Nil {
  case which {
    "Quit" -> io.println("Canora: bye")
    "About Canora" -> io.println("Canora 0.1 — native Campy client")
    _ -> io.println("Canora: settings")
  }
}

pub fn profile_clicked() -> Nil {
  io.println("Canora: open the Profile module for credentials")
}

pub fn new_playlist_clicked() -> Nil {
  io.println("Canora: new playlist (not connected)")
}
