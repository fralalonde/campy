// Hosts the language server's in-memory buffer for handler-code editing.
// Campy handler code lives in the project model; the IDE opens this module
// over LSP and keeps the live draft here, so `gleam lsp` can analyze it.
pub fn buffer_host() -> Nil {
  Nil
}
