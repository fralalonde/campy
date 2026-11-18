-module(campy_ide_wx_ffi).
-export([make_dir/1, write_file/2, compile_and_load/2]).

make_dir(Dir) ->
    case filelib:ensure_path(Dir) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

write_file(Path, Text) ->
    case file:write_file(Path, Text) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Build the scratch package at Dir with the Gleam CLI, add its ebin to the
%% code path, and ensure Module is loaded. Ok on success; an error message
%% with the compiler output on failure.
compile_and_load(Dir, Module) ->
    Cmd = "cd \"" ++ Dir ++ "\" && gleam build 2>&1",
    Out = os:cmd(Cmd),
    Ebin = filename:join([Dir, "build", "dev", "erlang", "campy_apps", "ebin"]),
    case code:add_patha(Ebin) of
        {error, Reason} ->
            {error, reason(Reason)};
        _ ->
            Atom = binary_to_atom(Module, utf8),
            case code:ensure_loaded(Atom) of
                {module, _} -> {ok, nil};
                {error, Reason2} ->
                    {error, unicode:characters_to_binary(
                              io_lib:format("~p: ~s", [Reason2, Out]))}
            end
    end.

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).


%% Build the scratch package at Dir with the Gleam CLI, add its ebin to the
%% code path, and ensure Module is loaded. Returns an error message on
%% failure; Ok on success.
compile_and_load(Dir, Module) ->
    Cmd = "cd \"" ++ Dir ++ "\" && gleam build 2>&1",
    case os:cmd(Cmd) of
        Out ->
            Ebin = filename:join([Dir, "build", "dev", "erlang", "campy_apps", "ebin"]),
            true = code:add_patha(Ebin),
            Atom = binary_to_atom(Module, utf8),
            case code:ensure_loaded(Atom) of
                {module, _} -> ok;
                {error, Reason} ->
                    {error, unicode:characters_to_binary(
                              io_lib:format("~s: ~p", [Reason, Out]))}
            end
    end.

send_stop(Subject) ->
    gleam@erlang@process:send(Subject, stop_request).
