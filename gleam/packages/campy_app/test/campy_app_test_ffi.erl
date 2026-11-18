-module(campy_app_test_ffi).
-export([decode_count/1]).

decode_count({state, Count}) -> {ok, Count};
decode_count(Other) -> {error, Other}.
