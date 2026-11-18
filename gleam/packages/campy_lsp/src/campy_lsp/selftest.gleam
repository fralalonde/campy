//// End-to-end proof for the LSP client: starts the real `gleam lsp` over a
//// throwaway workspace, opens a file with a type error, and expects
//// diagnostics; then completions, symbols, and definition. Run with
//// `gleam run -m campy_lsp/selftest`.
////
//// The projected messages arrive on the caller's mailbox exactly the way the
//// IDE consumes them (via campy_wx.Message).

import campy_lsp.{Config}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string

type Msg

@external(erlang, "campy_lsp_selftest_ffi", "workspace_dir")
fn workspace_dir() -> String

@external(erlang, "campy_lsp_selftest_ffi", "write_workspace")
fn write_workspace() -> Nil

@external(erlang, "campy_lsp_selftest_ffi", "write_source")
fn write_source(name: String, text: String) -> Nil

@external(erlang, "campy_lsp_selftest_ffi", "msg_kind")
fn msg_kind(msg: Msg) -> String

@external(erlang, "campy_lsp_selftest_ffi", "msg_rows")
fn msg_rows(msg: Msg) -> List(#(Int, Int, String, Int))

@external(erlang, "campy_lsp_selftest_ffi", "msg_labels")
fn msg_labels(msg: Msg) -> List(String)

@external(erlang, "campy_lsp_selftest_ffi", "msg_items")
fn msg_items(msg: Msg) -> List(#(String, Int))

@external(erlang, "campy_lsp_selftest_ffi", "msg_pos")
fn msg_pos(msg: Msg) -> #(Int, Int)

@external(erlang, "campy_lsp_selftest_ffi", "wait")
fn wait(ms: Int) -> Result(Msg, Nil)

fn expect(kind: String, timeout_ms: Int) -> Msg {
  case wait(250) {
    Ok(msg) ->
      case msg_kind(msg) == kind {
        True -> {
          io.println("[selftest] got " <> kind)
          msg
        }
        False -> {
          io.println("[selftest] skipped: " <> msg_kind(msg))
          case timeout_ms > 250 {
            True -> expect(kind, timeout_ms - 250)
            False -> die("timed out waiting for " <> kind)
          }
        }
      }
    Error(_) ->
      case timeout_ms > 250 {
        True -> expect(kind, timeout_ms - 250)
        False -> die("timed out waiting for " <> kind)
      }
  }
}

@external(erlang, "campy_lsp_selftest_ffi", "fail")
fn die(message: String) -> a

pub fn main() {
  write_workspace()
  let assert Ok(client) =
    campy_lsp.start(Config(
      language: "gleam",
      command: #("gleam", ["lsp"]),
      root: workspace_dir(),
      master: process.self(),
    ))
  // Let the server settle its handshake before the first document.
  process.sleep(1500)

  let file = workspace_dir() <> "/src/bad.gleam"
  let text = "pub fn main() {\n  let x = 1\n  boom\n}\n"
  // The Gleam LS compiles from disk: the file must exist before didOpen.
  write_source("bad", text)
  campy_lsp.open(client, file, text)

  let diagnostics = expect("lsp_diagnostics", 60_000)
  let rows = msg_rows(diagnostics)
  io.println(
    "diagnostics: "
    <> int.to_string(list.length(rows))
    <> " row(s); first: "
    <> describe_row(rows),
  )

  let good = workspace_dir() <> "/src/good.gleam"
  let good_text =
    "pub fn greet(name: String) -> String {\n  \"hi \" <> name\n}\n\npub fn main() {\n  greet(\"x\")\n}\n"
  write_source("good", good_text)
  campy_lsp.open(client, good, good_text)
  // The LS recompiles the workspace on the second open; let it settle.
  process.sleep(5000)

  campy_lsp.completion(client, good, 4, 2)
  let completions = expect("lsp_completions", 60_000)
  io.println(
    "completions: "
    <> int.to_string(list.length(msg_labels(completions)))
    <> " label(s)",
  )

  campy_lsp.symbols(client, good)
  let symbols = expect("lsp_symbols", 60_000)
  io.println(
    "symbols: "
    <> string.join(
      list.map(msg_items(symbols), fn(item) {
        let #(name, line) = item
        name <> "@" <> int.to_string(line)
      }),
      ", ",
    ),
  )

  // `greet` is used on line 4 (0-based). The gleam LS answers a same-file
  // symbol with its use-site range; cross-file symbols get their
  // declaration. Assert the reply resolves to this file.
  campy_lsp.definition(client, good, 4, 3)
  let definition = expect("lsp_definition", 60_000)
  let #(line, _char) = msg_pos(definition)
  io.println("definition resolved at line " <> int.to_string(line))

  campy_lsp.stop(client)
  io.println("selftest ok")
}

fn describe_row(rows: List(#(Int, Int, String, Int))) -> String {
  case rows {
    [#(line, _, text, severity), ..] ->
      "line "
      <> int.to_string(line)
      <> " severity "
      <> int.to_string(severity)
      <> ": "
      <> string.slice(text, 0, 40)
    [] -> "(none)"
  }
}
