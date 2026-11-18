-module(campy_app_test_ffi).
-export([decode_count/1, beam_path/1, code_which/1]).

code_which(Module) ->
    case code:which(binary_to_atom(Module, utf8)) of
        Path when is_list(Path) -> unicode:characters_to_binary(Path);
        Other -> unicode:characters_to_binary(io_lib:format("~p", [Other]))
    end.

beam_path(Module) ->
    case code:which(binary_to_atom(Module, utf8)) of
        Path when is_list(Path) -> unicode:characters_to_binary(Path);
        _ -> <<>>
    end.

decode_count({state, Count}) -> {ok, Count};
decode_count(Other) -> {error, Other}.
