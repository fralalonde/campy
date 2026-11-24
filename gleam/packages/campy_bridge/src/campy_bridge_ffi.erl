-module(campy_bridge_ffi).
-on_load(init/0).
-export([protocol_version/0, open_session/0, session_id/1,
         submit/2, close_session/1, poll/1, active_sessions/0,
         test_pump/1, test_pointer/3, test_resize/2,
         lsp_start/1, lsp_open/3, lsp_change/4, lsp_completions/4, lsp_stop/1]).

init() ->
    case os:getenv("CAMPY_NIF_DIR") of
        false -> {error, missing_campy_nif_dir};
        Directory -> erlang:load_nif(filename:join(Directory, "campy_bridge"), 0)
    end.

protocol_version() -> erlang:nif_error(nif_not_loaded).
test_pump(_Milliseconds) -> erlang:nif_error(ui_testing_feature_not_enabled).
test_pointer(_Action, _X, _Y) -> erlang:nif_error(ui_testing_feature_not_enabled).
test_resize(_Width, _Height) -> erlang:nif_error(ui_testing_feature_not_enabled).
active_sessions() -> erlang:nif_error(nif_not_loaded).
open_session() -> erlang:nif_error(nif_not_loaded).
session_id(_Session) -> erlang:nif_error(nif_not_loaded).
submit(_Session, _Command) -> erlang:nif_error(nif_not_loaded).
close_session(_Session) -> erlang:nif_error(nif_not_loaded).
lsp_start(_Root) -> erlang:nif_error(nif_not_loaded).
lsp_open(_Lsp, _Uri, _Text) -> erlang:nif_error(nif_not_loaded).
lsp_change(_Lsp, _Uri, _Version, _Text) -> erlang:nif_error(nif_not_loaded).
lsp_completions(_Lsp, _Uri, _Line, _Character) -> erlang:nif_error(nif_not_loaded).
lsp_stop(_Lsp) -> erlang:nif_error(nif_not_loaded).

poll(Timeout) when is_integer(Timeout), Timeout >= 0, Timeout =< 1000 ->
    receive
        {campy_event, Session, Generation, Kind, Payload} ->
            {some, {native_event, Session, Generation, Kind, Payload}}
    after Timeout -> none
    end.
