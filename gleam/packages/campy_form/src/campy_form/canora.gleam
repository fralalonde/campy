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
    menu("hamburger", "hamburger", 16, 14, 34, 30, "☰", [
      #("model", "Settings\nAbout Canora\nQuit"),
    ]),
    button("profile", "profile", 192, 14, 34, 30, "◉"),
    label("rail_title", "rail_title", 58, 20, 120, 28, "Your Library"),
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
    menu("hamburger", "hamburger", 24, 18, 34, 30, "☰", [
      #("model", "Settings\nAbout Canora\nQuit"),
    ]),
    label("heading", "heading", 70, 20, 500, 36, "Search"),
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
    menu("hamburger", "hamburger", 24, 18, 34, 30, "☰", [
      #("model", "Settings\nAbout Canora\nQuit"),
    ]),
    label("heading", "heading", 70, 20, 400, 36, "Profile"),
    label(
      "blurb",
      "blurb",
      24,
      66,
      760,
      40,
      "Canora speaks to Spotify and Tidal. Each service has its own app registration and token flow.",
    ),
    label(
      "provider_label",
      "provider_label",
      24,
      120,
      140,
      28,
      "Active service",
    ),
    control(
      "provider",
      "provider",
      campy_form.ComboBox,
      168,
      120,
      240,
      32,
      "Tidal",
      [
        #("model", "Spotify\nTidal"),
      ],
    ),
    label("spotify_heading", "spotify_heading", 24, 176, 400, 28, "Spotify"),
    label(
      "spotify_note",
      "spotify_note",
      24,
      204,
      760,
      22,
      "accounts.spotify.com/api/token · api.spotify.com/v1 · PKCE, refresh tokens",
    ),
    label("spotify_id_label", "spotify_id_label", 24, 234, 140, 28, "Client ID"),
    control(
      "spotify_id",
      "spotify_id",
      campy_form.EditBox,
      168,
      234,
      540,
      30,
      "",
      [
        #("placeholder", "Spotify application client id"),
      ],
    ),
    label(
      "spotify_token_label",
      "spotify_token_label",
      24,
      272,
      140,
      28,
      "Token",
    ),
    control(
      "spotify_token",
      "spotify_token",
      campy_form.EditBox,
      168,
      272,
      540,
      30,
      "",
      [
        #("placeholder", "bearer token (refreshed from the refresh token)"),
      ],
    ),
    label("tidal_heading", "tidal_heading", 24, 322, 400, 28, "Tidal"),
    label(
      "tidal_note",
      "tidal_note",
      24,
      350,
      760,
      22,
      "auth.tidal.com/v1/oauth2/token · openapi.tidal.com/v2 · countryCode required",
    ),
    label("tidal_id_label", "tidal_id_label", 24, 380, 140, 28, "Client ID"),
    control("tidal_id", "tidal_id", campy_form.EditBox, 168, 380, 540, 30, "", [
      #("placeholder", "Tidal application client id"),
    ]),
    label(
      "tidal_secret_label",
      "tidal_secret_label",
      24,
      418,
      140,
      28,
      "Client secret",
    ),
    control(
      "tidal_secret",
      "tidal_secret",
      campy_form.EditBox,
      168,
      418,
      540,
      30,
      "",
      [
        #("placeholder", "kept out of the form by a real deployment"),
      ],
    ),
    label("tidal_token_label", "tidal_token_label", 24, 456, 140, 28, "Token"),
    control(
      "tidal_token",
      "tidal_token",
      campy_form.EditBox,
      168,
      456,
      540,
      30,
      "",
      [
        #("placeholder", "bearer token from the token endpoint"),
      ],
    ),
    label(
      "tidal_country_label",
      "tidal_country_label",
      24,
      494,
      140,
      28,
      "Country",
    ),
    control(
      "tidal_country",
      "tidal_country",
      campy_form.EditBox,
      168,
      494,
      120,
      30,
      "US",
      [
        #("placeholder", "ISO 3166-1 alpha-2"),
      ],
    ),
    button("save", "save", 168, 540, 200, 34, "Save credentials"),
    button("connect", "connect", 380, 540, 160, 34, "Connect"),
    label(
      "status",
      "status",
      24,
      588,
      760,
      24,
      "Demo: reads assets/canora/tidal.json",
    ),
    list(
      "tidal_catalog",
      "tidal_catalog",
      24,
      620,
      700,
      180,
      "The Tidal catalogue appears here",
    ),
    datasource("tidal_api", "tidal_api", 752, 620, 68, 84, [
      #("url", "assets/canora/tidal.json"),
      #("target", "tidal_catalog"),
    ]),
  ]
  form("Canora · Profile", 880, 840, controls, [])
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

fn menu(
  id: String,
  name: String,
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  text: String,
  props: List(#(String, String)),
) {
  control(id, name, campy_form.Menu, x, y, w, h, text, props)
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
//
// The demo's handler code is real Gleam, kept in demo/canora/*.gleam and read
// when the project is built: the .campy file embeds the bytes, so the IDE can
// edit them, and the readable modules stay the source of truth for the demo.

@external(erlang, "campy_form_ffi", "read_demo")
fn read_demo(name: String) -> Result(String, String)

fn handler_source(name: String) -> String {
  case read_demo(name) {
    Ok(source) -> source
    Error(reason) -> panic as "Canora's handler source is missing: " <> reason
  }
}

fn library_source() -> String {
  handler_source("library.gleam")
}

fn search_source() -> String {
  handler_source("search.gleam")
}

fn connect_source() -> String {
  handler_source("connect.gleam")
}

fn player_source() -> String {
  handler_source("player.gleam")
}
