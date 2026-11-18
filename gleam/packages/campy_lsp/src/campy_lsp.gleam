//// Language server client (LSP over stdio) for the Campy editors.
////
//// The client is language-agnostic: `Config` names the server command (the
//// Gleam compiler ships one as `gleam lsp`; Rust-analyzer, Lua, ... would
//// work the same way), and the API below is the standard LSP surface the
//// editors need — open/change documents, completions, symbols, definitions
//// — with on-the-fly diagnostics pushed by the server.
////
//// Every asynchronous result arrives as a plain Erlang message on the
//// master process's mailbox, which the wx event loop surfaces as
//// `campy_wx.Message`:
////
////     {lsp_diagnostics, File, Rows}
////         Rows: List(#(Line, EndLine, Text, Severity))  (0-based lines)
////     {lsp_completions, File, Labels}                  Labels: List(String)
////     {lsp_symbols, File, Items}                       Items: List(#(Name, Line))
////     {lsp_definition, File, Line, Character}
////     {lsp_no_definition, File}
////     {lsp_down, Reason}
////

import gleam/erlang/process.{type Pid}

pub opaque type Client {
  Client(pid: Pid)
}

/// How to launch a language server for a workspace root.
pub type Config {
  Config(
    /// Human-readable language name ("gleam", ...).
    language: String,
    /// Command and arguments, e.g. #("gleam", ["lsp"]).
    command: #(String, List(String)),
    /// Workspace root directory (the server is spawned with this cwd).
    root: String,
    /// The process that receives result/diagnostic messages.
    master: Pid,
  )
}

@external(erlang, "campy_lsp_ffi", "start")
fn ffi_start(
  language: String,
  command: #(String, List(String)),
  root: String,
  master: Pid,
) -> Result(Pid, String)

@external(erlang, "campy_lsp_ffi", "stop")
fn ffi_stop(client: Pid) -> Nil

@external(erlang, "campy_lsp_ffi", "did_open")
fn ffi_did_open(client: Pid, file: String, text: String) -> Nil

@external(erlang, "campy_lsp_ffi", "did_change")
fn ffi_did_change(client: Pid, file: String, version: Int, text: String) -> Nil

@external(erlang, "campy_lsp_ffi", "completion")
fn ffi_completion(client: Pid, file: String, line: Int, character: Int) -> Nil

@external(erlang, "campy_lsp_ffi", "symbols")
fn ffi_symbols(client: Pid, file: String) -> Nil

@external(erlang, "campy_lsp_ffi", "definition")
fn ffi_definition(client: Pid, file: String, line: Int, character: Int) -> Nil

@external(erlang, "campy_lsp_ffi", "format")
fn ffi_format(client: Pid, file: String) -> Nil

/// Spawn the language server and run the LSP handshake. The server keeps
/// running until `stop`.
pub fn start(config: Config) -> Result(Client, String) {
  case ffi_start(config.language, config.command, config.root, config.master) {
    Ok(pid) -> Ok(Client(pid))
    Error(reason) -> Error(reason)
  }
}

/// Shut the language server down.
pub fn stop(client: Client) -> Nil {
  ffi_stop(client.pid)
}

/// Announce an opened document (full-text sync).
pub fn open(client: Client, file: String, text: String) -> Nil {
  ffi_did_open(client.pid, file, text)
}

/// Push the full text of an already-opened document.
pub fn change(client: Client, file: String, version: Int, text: String) -> Nil {
  ffi_did_change(client.pid, file, version, text)
}

/// Request completions at a position; the reply arrives as
/// `{lsp_completions, File, Labels}` on the master.
pub fn completion(
  client: Client,
  file: String,
  line: Int,
  character: Int,
) -> Nil {
  ffi_completion(client.pid, file, line, character)
}

/// Request the document's symbol outline; the reply arrives as
/// `{lsp_symbols, File, Items}`.
pub fn symbols(client: Client, file: String) -> Nil {
  ffi_symbols(client.pid, file)
}

/// Request the definition of the symbol at a position; the reply arrives as
/// `{lsp_definition, File, Line, Character}` (or `{lsp_no_definition, File}`).
pub fn definition(
  client: Client,
  file: String,
  line: Int,
  character: Int,
) -> Nil {
  ffi_definition(client.pid, file, line, character)
}

/// Request a formatted document; the reply arrives as
/// `{lsp_edits, File, Edits}` where Edits is `List(#(Line, NewText))`.
pub fn format(client: Client, file: String) -> Nil {
  ffi_format(client.pid, file)
}
