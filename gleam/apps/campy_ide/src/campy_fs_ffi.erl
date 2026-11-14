-module(campy_fs_ffi).
-export([list_dir/1, home/0, make_dir/1]).

%% Filesystem browsing for the in-app file dialog. Entries come back as
%% {Name, IsDir} pairs (binaries); the caller sorts and renders them.

home() ->
    Dir =
        case os:type() of
            {win32, _} -> os:getenv("USERPROFILE", "C:\\");
            _ -> os:getenv("HOME", "/")
        end,
    unicode:characters_to_binary(Dir).

list_dir(Path) ->
    case file:list_dir(unicode:characters_to_list(Path)) of
        {ok, Names} ->
            {ok,
                [{unicode:characters_to_binary(N),
                  filelib:is_dir(filename:join(unicode:characters_to_list(Path), N))}
                 || N <- Names]};
        {error, _} -> {error, nil}
    end.

make_dir(Path) ->
    case filelib:ensure_dir(unicode:characters_to_list(Path) ++ "/.") of
        ok -> {ok, nil};
        {error, Reason} -> error_text(Reason)
    end.

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
