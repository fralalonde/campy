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
