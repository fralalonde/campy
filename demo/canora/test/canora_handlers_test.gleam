import campy_form
import campy_form/project
import canora_project
import connect
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn a_form_body_is_percent_encoded_test() {
  connect.form_body([#("grant_type", "client_credentials"), #("scope", "a b")])
  |> should.equal("grant_type=client_credentials&scope=a%20b")
}

pub fn the_token_endpoints_differ_test() {
  connect.token_endpoint(connect.Spotify)
  |> should.equal("https://accounts.spotify.com/api/token")
  connect.token_endpoint(connect.Tidal)
  |> should.equal("https://auth.tidal.com/v1/oauth2/token")
  connect.api_base(connect.Spotify)
  |> should.equal("https://api.spotify.com/v1")
  connect.api_base(connect.Tidal)
  |> should.equal("https://openapi.tidal.com/v2")
}

pub fn tidal_urls_carry_a_country_test() {
  connect.with_country(
    connect.Tidal,
    "https://openapi.tidal.com/v2/search",
    "CA",
  )
  |> should.equal("https://openapi.tidal.com/v2/search?countryCode=CA")
  connect.with_country(
    connect.Tidal,
    "https://openapi.tidal.com/v2/search?x=1",
    "CA",
  )
  |> should.equal("https://openapi.tidal.com/v2/search?x=1&countryCode=CA")
  // Spotify reads the user's own market from the token.
  connect.with_country(connect.Spotify, "https://api.spotify.com/v1/me", "CA")
  |> should.equal("https://api.spotify.com/v1/me")
}

pub fn tokens_are_read_from_the_endpoints_answer_test() {
  connect.parse_tokens(
    "{\"access_token\":\"BQB-demo\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
  )
  |> should.equal(Ok(connect.Tokens("BQB-demo", None)))
  connect.parse_tokens(
    "{
  \"access_token\": \"abc\",
  \"refresh_token\": \"refresh-1\"
}",
  )
  |> should.equal(Ok(connect.Tokens("abc", Some("refresh-1"))))
  connect.parse_tokens("<html>not a token</html>")
  |> should.equal(Error("the token endpoint answered something else"))
}

pub fn the_spotify_authorize_url_is_a_pkce_request_test() {
  let url =
    connect.authorize_url(
      "client-1",
      "http://127.0.0.1:8888/callback",
      "challenge-1",
      "state-1",
    )
  [
    "client_id=client-1",
    "response_type=code",
    "code_challenge=challenge-1",
    "code_challenge_method=S256",
    "state=state-1",
    "redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback",
  ]
  |> list.each(fn(part) { string.contains(url, part) |> should.be_true })
}

fn module_of(loaded: project.Project, id: String) -> project.Module {
  let assert Some(module) = project.find_module(loaded, id)
  module
}

pub fn the_sample_project_roundtrips_with_real_handler_sources_test() {
  let path = "/tmp/canora-sample-roundtrip.campy"
  let demo = canora_project.project()
  demo.default_module |> should.equal("library")
  let assert Ok(_saved) = project.save(demo, path)
  let assert Ok(loaded) = project.load(path)
  loaded.modules
  |> list.map(fn(module) { module.name })
  |> should.equal(["Library", "Search", "Player", "Services"])
  // The non-visual components are part of the forms, with their properties.
  let library = module_of(loaded, "library")
  let timers =
    list.filter(library.form.controls, fn(control) {
      control.kind == campy_form.Timer
    })
  let datasources =
    list.filter(library.form.controls, fn(control) {
      control.kind == campy_form.Datasource
    })
  list.length(timers) |> should.equal(1)
  list.length(datasources) |> should.equal(1)
  let assert [timer, ..] = timers
  campy_form.control_prop(timer, "target", "") |> should.equal("progress")
  // The page is free-layout: the panels are backgrounds and every child sits
  // where it belongs on the page.
  library.form.aligns |> should.equal([])
  // The Services module points a datasource at the Tidal catalogue and carries
  // both services' credentials.
  let services = module_of(loaded, "connect")
  let urls =
    list.filter(services.form.controls, fn(control) {
      control.kind == campy_form.Datasource
    })
    |> list.map(fn(control) { campy_form.control_prop(control, "url", "") })
  urls |> should.equal(["assets/canora/tidal.json"])
  services.form.controls
  |> list.any(fn(control) { control.name == "provider" })
  |> should.be_true
  let names = list.map(services.form.controls, fn(control) { control.name })
  list.each(
    [
      "spotify_id",
      "spotify_token",
      "tidal_id",
      "tidal_secret",
      "tidal_token",
      "tidal_country",
    ],
    fn(name) { list.contains(names, name) |> should.be_true },
  )
  // The hamburger menu is on the app's own forms, with its three items.
  let assert Ok(hamburger) =
    list.find(library.form.controls, fn(control) { control.name == "hamburger" })
  hamburger.kind |> should.equal(campy_form.Menu)
  campy_form.control_prop(hamburger, "model", "")
  |> should.equal("Settings\nAbout Canora\nQuit")
  library.form.controls
  |> list.any(fn(control) { control.name == "profile" })
  |> should.be_true
  // The handler sources are real Gleam, not stubs.
  let assert project.Embedded(library_source) = library.source_origin
  string.contains(library_source, "import gleam/list") |> should.be_true
  string.contains(library_source, "persistent_term") |> should.be_true
  string.contains(library_source, "TODO") |> should.be_false
  let player_module = module_of(loaded, "player")
  let assert project.Embedded(player_source) = player_module.source_origin
  string.contains(player_source, "pub fn shuffle_clicked") |> should.be_true
  string.contains(player_source, "TODO") |> should.be_false
  let assert project.Embedded(connect_source) = services.source_origin
  string.contains(connect_source, "accounts.spotify.com/api/token")
  |> should.be_true
  string.contains(connect_source, "auth.tidal.com/v1/oauth2/token")
  |> should.be_true
  string.contains(connect_source, "countryCode") |> should.be_true
  string.contains(connect_source, "TODO") |> should.be_false
}
