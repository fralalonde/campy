-module(campy_lsp_ffi).
-export([put/1, get/0, cwd/0]).

%% The language-server handle lives in a persistent term so the IDE loop (and
%% the F6 hot-reload path, which re-enters campy_ide:loop with fresh state)
%% can reach it without threading it through every call.

put(Handle) ->
    persistent_term:put(campy_ide_lsp, Handle),
    nil.

get() ->
    case persistent_term:get(campy_ide_lsp, undefined) of
        undefined -> {error, nil};
        Handle -> {ok, Handle}
    end.

cwd() ->
    {ok, Cwd} = file:get_cwd(),
    unicode:characters_to_binary(Cwd).
