//// Canora, as a Campy project: the shapes of a native Spotify client (library,
//// search, now playing) built from forms, plus the two non-visual components a
//// client needs — a timer that advances the transport and a datasource that
//// fills the lists.
////
//// This is the project `projects/canora.campy` is written from, so the demo can
//// be regenerated and is checked like any other form. Handlers are ordinary
//// Gleam module sources, embedded so the whole project is editable in the IDE.

import campy_form
import campy_form/project
import gleam/list

pub const path = "projects/canora.campy"

pub fn project() -> project.Project {
  project.Project(
    project.version,
    "Canora",
    [
      project.Module(
        "library",
        "Library",
        library(),
        project.Embedded(library_source()),
      ),
      project.Module(
        "search",
        "Search",
        search(),
        project.Embedded(search_source()),
      ),
      project.Module(
        "player",
        "Player",
        player(),
        project.Embedded(player_source()),
      ),
      project.Module(
        "connect",
        "Services",
        connect(),
        project.Embedded(connect_source()),
      ),
    ],
    path,
    "",
    "library",
  )
}

// --- library ----------------------------------------------------------------

fn library() -> campy_form.Form {
  let controls = [
    panel("rail", "rail", 0, 0, 240, 640, ""),
    label("rail_title", "rail_title", 20, 20, 200, 28, "Your Library"),
    list(
      "playlist_list",
      "playlist_list",
      16,
      60,
      208,
      260,
      "Discover Weekly\nRelease Radar\nDaily Mix 1\nLiked Songs\nMochi FM",
    ),
    label(
      "rail_note",
      "rail_note",
      20,
      340,
      200,
      40,
      "Filled by the datasource",
    ),
    button("new_playlist", "new_playlist", 16, 496, 208, 34, "+ New playlist"),
    panel("now_playing", "now_playing", 0, 544, 980, 96, ""),
    label("cover", "cover", 24, 556, 72, 72, "♫"),
    label("track", "track", 112, 560, 380, 26, "Mochi Sunrise"),
    label("artist", "artist", 112, 588, 380, 22, "The Cat Café Collective"),
    progress("progress", "progress", 112, 616, 380, 12, 0),
    button("prev", "prev", 520, 576, 40, 34, "⏮"),
    button("play", "play", 566, 576, 48, 34, "▶"),
    button("next", "next", 620, 576, 40, 34, "⏭"),
    button("volume", "volume", 700, 576, 40, 34, "🔈"),
    progress("volume_bar", "volume_bar", 748, 588, 120, 10, 60),
    label("format", "format", 884, 580, 80, 20, "FLAC · 44.1"),
    panel("main", "main", 240, 0, 740, 544, ""),
    label("heading", "heading", 268, 24, 600, 40, "Listen now"),
    label(
      "subheading",
      "subheading",
      268,
      70,
      600,
      22,
      "Made for you — filled by tracks_api",
    ),
    list(
      "tracks",
      "tracks",
      268,
      104,
      680,
      330,
      "Connecting to the datasource…",
    ),
    datasource("tracks_api", "tracks_api", 268, 448, 150, 84, [
      #("url", "assets/canora/tracks.json"),
      #("target", "tracks"),
    ]),
    timer("playback_timer", "playback_timer", 440, 448, 130, 84, [
      #("interval", "1000"),
      #("target", "progress"),
      #("step", "1"),
      #("maximum", "100"),
    ]),
  ]
  form("Canora · Library", 980, 640, controls, [])
}

// --- search -----------------------------------------------------------------

fn search() -> campy_form.Form {
  let controls = [
    label("heading", "heading", 24, 20, 500, 36, "Search"),
    edit("query", "query", 24, 68, 640, 36, "mochi", [
      #("placeholder", "Tracks, artists, albums, playlists"),
    ]),
    button("go", "go", 676, 68, 120, 36, "Search"),
    button("clear", "clear", 804, 68, 72, 36, "Clear"),
    label(
      "hint",
      "hint",
      24,
      116,
      700,
      22,
      "Results are filled by results_api; the real API needs a token.",
    ),
    list(
      "results",
      "results",
      24,
      148,
      852,
      420,
      "Type a query and press Search",
    ),
    datasource("results_api", "results_api", 24, 578, 150, 30, [
      #("url", "assets/canora/search.json"),
      #("target", "results"),
    ]),
  ]
  form("Canora · Search", 900, 620, controls, [])
}

// --- player -----------------------------------------------------------------

fn player() -> campy_form.Form {
  let controls = [
    panel("stage", "stage", 20, 20, 480, 480, ""),

    label("cover", "cover", 44, 44, 432, 432, "♫"),
    label("title", "title", 20, 512, 480, 32, "Mochi Sunrise"),
    label("artist", "artist", 20, 546, 480, 24, "The Cat Café Collective"),
    progress("elapsed", "elapsed", 20, 580, 480, 14, 0),
    button("shuffle", "shuffle", 20, 606, 56, 36, "🔀"),
    button("prev", "prev", 84, 606, 56, 36, "⏮"),
    button("play", "play", 148, 602, 64, 44, "▶"),
    button("next", "next", 220, 606, 56, 36, "⏭"),
    button("repeat", "repeat", 284, 606, 56, 36, "🔁"),
    label("heart", "heart", 440, 606, 60, 36, "♥"),
    list("queue", "queue", 20, 656, 480, 48, "Queue"),
    datasource("queue_api", "queue_api", 340, 584, 150, 30, [
      #("url", "assets/canora/queue.json"),
      #("target", "queue"),
    ]),
    timer("elapsed_timer", "elapsed_timer", 20, 584, 150, 30, [
      #("interval", "1000"),
      #("target", "elapsed"),
      #("step", "1"),
      #("maximum", "240"),
    ]),
  ]
  form("Canora · Now playing", 520, 720, controls, [])
}

// --- connect ----------------------------------------------------------------

/// Which service the client talks to. Tidal and Spotify are both ordinary
/// datasources behind a token, so the choice is one combo and one field.
fn connect() -> campy_form.Form {
  let controls = [
    label("heading", "heading", 24, 20, 500, 36, "Services"),
    label(
      "blurb",
      "blurb",
      24,
      62,
      640,
      40,
      "Canora speaks to Spotify and Tidal: pick one, paste a token, and the catalogue loads.",
    ),
    label("provider_label", "provider_label", 24, 116, 140, 28, "Service"),
    control(
      "provider",
      "provider",
      campy_form.ComboBox,
      168,
      116,
      240,
      32,
      "Tidal",
      [
        #("model", "Spotify\nTidal"),
      ],
    ),
    label("token_label", "token_label", 24, 156, 140, 28, "Token"),
    control("token", "token", campy_form.EditBox, 168, 156, 500, 32, "", [
      #("placeholder", "paste an access token"),
    ]),
    button("connect", "connect", 168, 196, 140, 34, "Connect"),
    label(
      "status",
      "status",
      24,
      246,
      640,
      24,
      "Not connected — the demo reads a local export",
    ),
    list(
      "tidal_catalog",
      "tidal_catalog",
      24,
      280,
      640,
      280,
      "The Tidal catalogue appears here",
    ),
    datasource("tidal_api", "tidal_api", 692, 280, 150, 84, [
      #("url", "assets/canora/tidal.json"),
      #("target", "tidal_catalog"),
    ]),
  ]
  form("Canora · Services", 880, 600, controls, [])
}

// --- builders ---------------------------------------------------------------

fn form(
  title: String,
  width: Int,
  height: Int,
  controls: List(campy_form.Control),
  aligns: List(#(String, campy_form.Align)),
) -> campy_form.Form {
  campy_form.Form(
    "campy.canora",
    title,
    width,
    height,
    campy_form.Free,
    controls,
    list.map(controls, fn(control) { #(control.id, "") }),
    aligns,
    [],
    [#("", 0)],
    [],
    [],
  )
}

fn panel(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
) {
  control(id, name, campy_form.Panel, x, y, w, h, text, [#("border", "0")])
}

fn label(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
) {
  control(id, name, campy_form.Label, x, y, w, h, text, [])
}

fn button(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
) {
  control(id, name, campy_form.Button, x, y, w, h, text, [])
}

fn list(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
) {
  control(id, name, campy_form.ListBox, x, y, w, h, text, [])
}

fn edit(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
  props: List(#(String, String)),
) {
  control(id, name, campy_form.EditBox, x, y, w, h, text, props)
}

fn progress(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  value: Int,
) {
  control(id, name, campy_form.Progress, x, y, w, h, "", [
    #("value", int_to_string(value)),
  ])
}

fn timer(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  props: List(#(String, String)),
) {
  control(id, name, campy_form.Timer, x, y, w, h, name, props)
}

fn datasource(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  props: List(#(String, String)),
) {
  control(id, name, campy_form.Datasource, x, y, w, h, name, props)
}

fn control(
  id: String,
  name: String,
  kind: campy_form.Kind,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
  props: List(#(String, String)),
) {
  campy_form.Control(id, name, kind, x, y, w, h, text, True, True, props)
}

fn int_to_string(value: Int) -> String {
  case value {
    0 -> "0"
    _ -> int_to_string_positive(value, "")
  }
}

fn int_to_string_positive(value: Int, acc: String) -> String {
  let digit = value % 10
  let digit_text = case digit {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    _ -> "9"
  }
  let acc = digit_text <> acc
  case value / 10 {
    0 -> acc
    next -> int_to_string_positive(next, acc)
  }
}

// --- handlers ---------------------------------------------------------------

fn library_source() -> String {
  "// Canora · library
//
// Every function here is a handler: the component with this name answers the
// event. The two non-visual components are hosted for you — playback_timer
// ticks into `progress`, tracks_api fills `tracks` — and their own events
// arrive as playback_timer_tick / tracks_api_loaded.
//
// A real deployment would read the Web API with a token it keeps out of the
// form; the demo datasource reads assets/canora/tracks.json, so the list fills
// without a login.

pub fn play_clicked() -> Nil {
  // Start or resume: the transport speaks to the player, not to the UI.
  Nil
}

pub fn next_clicked() -> Nil {
  Nil
}

pub fn prev_clicked() -> Nil {
  Nil
}

pub fn new_playlist_clicked() -> Nil {
  Nil
}

pub fn tracks_api_loaded(count: Int) -> Nil {
  let _ = count
  Nil
}

pub fn playback_timer_tick() -> Nil {
  Nil
}
"
}

fn search_source() -> String {
  "// Canora · search

pub fn go_clicked() -> Nil {
  // `query` holds the term; results_api fills the list.
  Nil
}

pub fn clear_clicked() -> Nil {
  Nil
}

pub fn results_api_loaded(count: Int) -> Nil {
  let _ = count
  Nil
}
"
}

fn connect_source() -> String {
  "// Canora · services
//
// One client, two services. `provider` picks Spotify or Tidal, `token` holds
// the access token, and the catalogue datasource reads what the service
// answers. The demo reads assets/canora/tidal.json, so there is no login; a
// real deployment trades a refresh token for an access token here.
//
// Tidal:   https://openapi.tidal.com/v2/searchResults/{query}?countryCode=…
//          Authorization: Bearer <token>
// Spotify: https://api.spotify.com/v1/search?q=…&type=track
//          Authorization: Bearer <token>

pub type Provider {
  Spotify
  Tidal
}

pub fn provider_selected(which: String) -> Nil {
  let provider = case which {
    \"Spotify\" -> Spotify
    _ -> Tidal
  }
  let _ = provider
  Nil
}

pub fn connect_clicked() -> Nil {
  // `token` holds the service's access token; the datasource then reads the
  // catalogue it is pointed at.
  Nil
}

pub fn tidal_api_loaded(count: Int) -> Nil {
  let _ = count
  Nil
}
"
}

fn player_source() -> String {
  "// Canora · now playing

pub fn play_clicked() -> Nil {
  Nil
}

pub fn next_clicked() -> Nil {
  Nil
}

pub fn prev_clicked() -> Nil {
  Nil
}

pub fn shuffle_clicked() -> Nil {
  Nil
}

pub fn repeat_clicked() -> Nil {
  Nil
}

pub fn heart_clicked() -> Nil {
  Nil
}
"
}
