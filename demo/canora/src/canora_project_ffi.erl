-module(canora_project_ffi).
-export([read_source/1]).

%% The demo's handler sources, read beside this package when `just demo` builds
%% examples/canora.campy. Sample-only: Campy core never calls this.
read_source(Name) ->
    Local = filename:join(["src", binary_to_list(Name)]),
    Path = case filelib:is_regular(Local) of
        true -> Local;
        false ->
            Root = case os:getenv("CAMPY_ROOT") of
                false -> ".";
                Value -> Value
            end,
            filename:join([Root, "demo/canora/src", binary_to_list(Name)])
    end,
    case file:read_file(Path) of
        {ok, Source} -> {ok, Source};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                io_lib:format("cannot read ~s: ~p", [Path, Reason]))}
    end.
