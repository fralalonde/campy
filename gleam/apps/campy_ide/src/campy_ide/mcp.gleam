import gleam/option.{type Option}

// Bridge to the localhost MCP HTTP server. The IDE loop is the owner; tool
// calls arrive as {handle, tool, arg} and are answered through `reply`.
@external(erlang, "campy_mcp", "start")
pub fn start(port: Int) -> Result(Nil, String)

@external(erlang, "campy_mcp", "stop")
pub fn stop() -> Result(Nil, String)

@external(erlang, "campy_mcp", "status")
pub fn status() -> String

@external(erlang, "campy_mcp", "next_request")
pub fn next_request() -> Option(#(Int, String, String))

@external(erlang, "campy_mcp", "reply")
pub fn reply(handle: Int, text: String, is_error: Bool) -> Nil

@external(erlang, "campy_mcp", "test_handle")
pub fn test_handle(body: String) -> String

@external(erlang, "campy_mcp", "test_post")
pub fn test_post(port: Int, body: String) -> String
