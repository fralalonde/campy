// Canora · services — credentials and token flows for Spotify and Tidal.
//
// The two services are not the same API, and the differences matter:
//
// Spotify — OAuth 2.0 authorization code with PKCE (the flow for a desktop
// client, which cannot keep a secret):
//   authorize  GET  https://accounts.spotify.com/authorize
//                   client_id, response_type=code, redirect_uri, scope,
//                   code_challenge, code_challenge_method=S256, state
//   token      POST https://accounts.spotify.com/api/token
//                   grant_type=authorization_code, code, redirect_uri,
//                   client_id, code_verifier
//   refresh    POST https://accounts.spotify.com/api/token
//                   grant_type=refresh_token, refresh_token, client_id
//   API        https://api.spotify.com/v1/...        Authorization: Bearer …
//
// Tidal — OAuth 2.0 client credentials for an application (a desktop app ships
// its client id and secret), and every API request carries a country:
//   token      POST https://auth.tidal.com/v1/oauth2/token
//                   grant_type=client_credentials, client_id, client_secret
//   API        https://openapi.tidal.com/v2/...?countryCode=US
//                                              Authorization: Bearer …
//
// Credentials live in persistent_term here, which is what a generated app has
// without a database. A shipping client would put the secret in the desktop
// keyring instead, and never in the form; the fields on this form are drafts
// until Save, and the demo datasource keeps reading assets/canora/tidal.json so
// the app still runs without a login.
//
// Only the standard library is used: `percent_encode` is OTP's uri_string, and
// the one network call goes through the app runtime's `post_form`.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Provider {
  Spotify
  Tidal
}

pub type Credentials {
  Credentials(
    client_id: String,
    client_secret: String,
    access_token: String,
    refresh_token: String,
    country: String,
  )
}

pub type Tokens {
  Tokens(access_token: String, refresh_token: Option(String))
}

const credentials_key = "canora.credentials"

const token_key = "canora.token"

const provider_key = "canora.provider"

// The form's draft fields, before Save.
const spotify_id_key = "canora.draft.spotify.id"

const spotify_token_key = "canora.draft.spotify.token"

const tidal_id_key = "canora.draft.tidal.id"

const tidal_secret_key = "canora.draft.tidal.secret"

const tidal_token_key = "canora.draft.tidal.token"

const tidal_country_key = "canora.draft.tidal.country"

@external(erlang, "persistent_term", "get")
fn stored_credentials(
  key: String,
  default: Option(Credentials),
) -> Option(Credentials)

@external(erlang, "persistent_term", "put")
fn remember_credentials(key: String, value: Option(Credentials)) -> Nil

@external(erlang, "persistent_term", "get")
fn stored_text(key: String, default: String) -> String

@external(erlang, "persistent_term", "put")
fn remember_text(key: String, value: String) -> Nil

@external(erlang, "uri_string", "quote")
fn percent_encode(text: String) -> String

// POST a form body and return the response body; the host owns inets and the
// status/error mapping, so a handler needs no HTTP package.
@external(erlang, "campy_app_ffi", "post_form")
fn post_form(url: String, body: String) -> Result(String, String)

pub fn provider_name(provider: Provider) -> String {
  case provider {
    Spotify -> "Spotify"
    Tidal -> "Tidal"
  }
}

pub fn provider_of(name: String) -> Provider {
  case string.lowercase(name) {
    "spotify" -> Spotify
    _ -> Tidal
  }
}

/// Where a provider's tokens come from, and what a bearer token unlocks.
pub fn token_endpoint(provider: Provider) -> String {
  case provider {
    Spotify -> "https://accounts.spotify.com/api/token"
    Tidal -> "https://auth.tidal.com/v1/oauth2/token"
  }
}

pub fn api_base(provider: Provider) -> String {
  case provider {
    Spotify -> "https://api.spotify.com/v1"
    Tidal -> "https://openapi.tidal.com/v2"
  }
}

pub fn scopes(provider: Provider) -> String {
  case provider {
    // Spotify wants the scopes at authorize time, space separated.
    Spotify ->
      "user-read-playback-state user-modify-playback-state user-library-read playlist-read-private"
    // Tidal's client credentials carry the app's own rights; no scopes.
    Tidal -> ""
  }
}

/// A form body is percent-encoded `key=value` pairs joined with `&`. Encoded
/// with the URI rules, so a client id with `+` or `:` survives.
pub fn form_body(fields: List(#(String, String))) -> String {
  fields
  |> list.map(fn(pair) {
    let #(key, value) = pair
    percent_encode(key) <> "=" <> percent_encode(value)
  })
  |> string.join("&")
}

/// The URL the desktop browser opens for Spotify's PKCE flow. `challenge` is
/// BASE64URL(SHA256(verifier)) without padding, `state` is the caller's
/// anti-CSRF value and comes back on the redirect.
pub fn authorize_url(
  client_id: String,
  redirect_uri: String,
  challenge: String,
  state: String,
) -> String {
  "https://accounts.spotify.com/authorize?"
  <> form_body([
    #("client_id", client_id),
    #("response_type", "code"),
    #("redirect_uri", redirect_uri),
    #("scope", scopes(Spotify)),
    #("code_challenge", challenge),
    #("code_challenge_method", "S256"),
    #("state", state),
  ])
}

/// Spotify's code-for-token exchange. The PKCE verifier is the secret here;
/// there is no client secret in a desktop app.
pub fn authorization_code_body(
  client_id: String,
  code: String,
  redirect_uri: String,
  verifier: String,
) -> String {
  form_body([
    #("grant_type", "authorization_code"),
    #("code", code),
    #("redirect_uri", redirect_uri),
    #("client_id", client_id),
    #("code_verifier", verifier),
  ])
}

pub fn refresh_body(client_id: String, refresh_token: String) -> String {
  form_body([
    #("grant_type", "refresh_token"),
    #("refresh_token", refresh_token),
    #("client_id", client_id),
  ])
}

/// Tidal's only exchange: the application authenticates itself.
pub fn client_credentials_body(client_id: String, secret: String) -> String {
  form_body([
    #("grant_type", "client_credentials"),
    #("client_id", client_id),
    #("client_secret", secret),
  ])
}

/// The token endpoints answer a small JSON object; these two fields are all a
/// client needs, so the parser is a string scan rather than a JSON dependency.
pub fn parse_tokens(body: String) -> Result(Tokens, String) {
  case json_string(body, "access_token") {
    None -> Error("the token endpoint answered something else")
    Some(access_token) -> {
      let refresh_token = case json_string(body, "refresh_token") {
        Some("") -> None
        found -> found
      }
      Ok(Tokens(access_token, refresh_token))
    }
  }
}

fn json_string(body: String, key: String) -> Option(String) {
  let needle = "\"" <> key <> "\""
  case string.split(body, needle) {
    [_, after_key] -> {
      let after_colon =
        after_key
        |> string.trim_start()
        |> drop_prefix(":")
        |> string.trim_start()
      case string.starts_with(after_colon, "\"") {
        True ->
          case
            after_colon
            |> string.drop_start(1)
            |> string.split("\"")
            |> list.first()
          {
            Ok(value) -> Some(value)
            Error(_) -> None
          }
        False -> None
      }
    }
    _ -> None
  }
}

fn drop_prefix(text: String, prefix: String) -> String {
  case string.starts_with(text, prefix) {
    True -> string.drop_start(text, string.length(prefix))
    False -> text
  }
}

/// Tidal's requests need the account's market; Spotify reads the user's own.
pub fn with_country(
  provider: Provider,
  url: String,
  country: String,
) -> String {
  case provider {
    Spotify -> url
    Tidal ->
      case string.contains(url, "countryCode=") {
        True -> url
        False ->
          case string.contains(url, "?") {
            True -> url <> "&countryCode=" <> percent_encode(country)
            False -> url <> "?countryCode=" <> percent_encode(country)
          }
      }
  }
}

// --- the form's handlers -----------------------------------------------------

/// Field edits hold drafts; Save validates the selected service's client id,
/// and only then stores the credentials.
pub fn provider_selected(which: String) -> Nil {
  let provider = provider_of(which)
  remember_text(provider_key, provider_name(provider))
  io.println("Canora: active service " <> provider_name(provider))
}

pub fn spotify_id_edited(text: String) -> Nil {
  remember_text(spotify_id_key, text)
}

pub fn spotify_token_edited(text: String) -> Nil {
  remember_text(spotify_token_key, text)
}

pub fn tidal_id_edited(text: String) -> Nil {
  remember_text(tidal_id_key, text)
}

pub fn tidal_secret_edited(text: String) -> Nil {
  remember_text(tidal_secret_key, text)
}

pub fn tidal_token_edited(text: String) -> Nil {
  remember_text(tidal_token_key, text)
}

pub fn tidal_country_edited(text: String) -> Nil {
  remember_text(tidal_country_key, text)
}

pub fn save_clicked() -> Nil {
  let provider = provider_of(read_text(provider_key, "Tidal"))
  let draft =
    Credentials(
      client_id: draft_id(provider),
      client_secret: draft_secret(provider),
      access_token: draft_token(provider),
      refresh_token: "",
      country: draft_country(provider),
    )
  case string.trim(draft.client_id) {
    "" ->
      io.println("Canora: " <> provider_name(provider) <> " needs a client id")
    _ -> {
      remember_credentials(credentials_key, Some(draft))
      io.println("Canora: saved " <> provider_name(provider) <> " credentials")
    }
  }
}

pub fn connect_clicked() -> Nil {
  case stored_credentials(credentials_key, None) {
    None -> io.println("Canora: save credentials before connecting")
    Some(credentials) -> {
      let provider = provider_of(read_text(provider_key, "Tidal"))
      let body = case provider {
        // The desktop flow begins in the browser; the token arrives by
        // redirect, so Connect only shows the exchange it would complete.
        Spotify ->
          authorization_code_body(
            credentials.client_id,
            "",
            read_text("canora.redirect_uri", ""),
            read_text("canora.code_verifier", ""),
          )
        Tidal ->
          client_credentials_body(
            credentials.client_id,
            credentials.client_secret,
          )
      }
      case post_form(token_endpoint(provider), body) {
        Ok(response) ->
          case parse_tokens(response) {
            Ok(tokens) -> {
              remember_credentials(
                credentials_key,
                Some(
                  Credentials(..credentials, access_token: tokens.access_token),
                ),
              )
              remember_text(token_key, tokens.access_token)
              io.println(
                "Canora: "
                <> provider_name(provider)
                <> " connected · "
                <> api_base(provider)
                <> with_country(
                  provider,
                  "/search?query=canora",
                  credentials.country,
                ),
              )
            }
            Error(reason) -> io.println("Canora: " <> reason)
          }
        Error(reason) -> {
          // No network here: the demo catalogue still plays.
          io.println(
            "Canora: "
            <> provider_name(provider)
            <> " unreachable ("
            <> reason
            <> ")",
          )
          io.println("Canora: playing from assets/canora/tidal.json")
        }
      }
    }
  }
}

pub fn tidal_api_loaded(count: Int) -> Nil {
  io.println("Canora: catalogue holds " <> int.to_string(count) <> " tracks")
}

pub fn hamburger_selected(which: String) -> Nil {
  case which {
    "Quit" -> io.println("Canora: bye")
    "About Canora" -> io.println("Canora 0.1 — native Campy client")
    _ -> io.println("Canora: settings")
  }
}

fn draft_id(provider: Provider) -> String {
  case provider {
    Spotify -> read_text(spotify_id_key, "")
    Tidal -> read_text(tidal_id_key, "")
  }
}

fn draft_secret(provider: Provider) -> String {
  case provider {
    // Spotify's PKCE flow has no client secret.
    Spotify -> ""
    Tidal -> read_text(tidal_secret_key, "")
  }
}

fn draft_token(provider: Provider) -> String {
  case provider {
    Spotify -> read_text(spotify_token_key, "")
    Tidal -> read_text(tidal_token_key, "")
  }
}

fn draft_country(provider: Provider) -> String {
  case provider {
    Spotify -> ""
    Tidal ->
      case read_text(tidal_country_key, "") {
        "" -> "US"
        country -> country
      }
  }
}

fn read_text(key: String, default: String) -> String {
  stored_text(key, default)
}
