-module(campy_runner_test_ffi).
-export([wrap/1, unwrap_result/1]).

wrap(Term) -> Term.

%% The transport wraps the peer's return value: start_app already returns a
%% Result, so the IDE sees {ok, {ok, Subject}}; strip the transport layer.
unwrap_result({ok, {ok, Value}}) -> {ok, Value};
unwrap_result({ok, {error, Reason}}) -> {error, Reason};
unwrap_result({error, Reason}) -> {error, Reason}.
