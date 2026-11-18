-module(campy_peer_test_ffi).
-export([wrap_int/1, read_int/1]).

%% Ints cross the FFI boundary as raw Erlang integers; the dynamic-typed list
%% argument in Gleam is a plain list of terms on the Erlang side.
wrap_int(Value) -> Value.

read_int(Value) -> Value.
