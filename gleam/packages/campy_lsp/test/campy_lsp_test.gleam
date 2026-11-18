//// Unit tests for the LSP package's pure helpers. The end-to-end flow (real
//// `gleam lsp` over stdio) lives in `campy_lsp/selftest`, runnable with
//// `gleam run -m campy_lsp/selftest` — the LS spawns subprocesses and takes
//// tens of seconds on a cold workspace, which does not fit eunit's harness.

import gleeunit

pub fn main() {
  gleeunit.main()
}
