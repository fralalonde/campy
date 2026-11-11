-module(campy_bridge_ffi).
-on_load(init/0).
-export([protocol_version/0, validate_ui/1, open_session/0, session_id/1,
         submit/2, close_session/1, poll/1, active_sessions/0, test_input/3]).

init() ->
    case os:getenv("CAMPY_NIF_DIR") of
        false -> {error, missing_campy_nif_dir};
        Directory -> erlang:load_nif(filename:join(Directory, "campy_bridge"), 0)
    end.

protocol_version() -> erlang:nif_error(nif_not_loaded).
validate_ui(_Source) -> erlang:nif_error(nif_not_loaded).
test_input(_Session, _Generation, _Input) -> erlang:nif_error(ui_testing_feature_not_enabled).
active_sessions() -> erlang:nif_error(nif_not_loaded).
open_session() -> erlang:nif_error(nif_not_loaded).
session_id(_Session) -> erlang:nif_error(nif_not_loaded).
submit(_Session, _Command) -> erlang:nif_error(nif_not_loaded).
close_session(_Session) -> erlang:nif_error(nif_not_loaded).

poll(Timeout) when is_integer(Timeout), Timeout >= 0, Timeout =< 1000 ->
    receive
        {campy_event, Session, Generation, Kind, Payload} ->
            {some, {native_event, Session, Generation, Kind, Payload}}
    after Timeout -> none
    end.

