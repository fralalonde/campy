-module(campy_hot_ffi).
-export([reload/0, continue/7]).

%% F6 development loop: rebuild the Gleam app, hot-load its Beams into the
%% running VM, and re-enter the (possibly new) IDE loop. Rust/NIF changes still
%% need a process restart.
reload() ->
    Root = case os:getenv("CAMPY_ROOT") of
        false -> ".";
        Value -> Value
    end,
    App = filename:join([Root, "gleam", "apps", "campy_ide"]),
    case run_build(App) of
        {ok, _Output} ->
            reload_modules(filename:absname(filename:join([App, "build", "dev", "erlang"])));
        {error, Error} ->
            {error, Error}
    end.

%% Every loop iteration goes through an external call, so a hot-loaded
%% campy_ide:loop/7 is used on the next iteration.
continue(Session, SessionId, Model, Submitted, Accepted, Last, Heartbeat) ->
    campy_ide:loop(Session, SessionId, Model, Submitted, Accepted, Last, Heartbeat).

run_build(App) ->
    case os:find_executable("gleam") of
        false ->
            {error, <<"gleam executable not found">>};
        Exe ->
            Port = open_port({spawn_executable, Exe},
                             [{cd, App}, {args, ["build"]}, binary,
                              exit_status, stderr_to_stdout]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Code}} ->
            {error, <<"gleam build failed (", (integer_to_binary(Code))/binary,
                      "): ", Acc/binary>>}
    after 180000 ->
        catch port_close(Port),
        {error, <<"gleam build timed out">>}
    end.

reload_modules(BuildRoot) ->
    Candidates = [Mod || {Mod, Beam} <- code:all_loaded(),
                         is_list(Beam),
                         lists:prefix(BuildRoot, Beam),
                         is_campy_module(Beam),
                         Mod =/= campy_bridge_ffi,
                         Mod =/= campy_hot_ffi],
    Results = [reload_one(Mod) || Mod <- Candidates],
    Reloaded = length([ok || ok <- Results]),
    case [Error || {error, Error} <- Results] of
        [] ->
            {ok, Reloaded};
        Errors ->
            Text = unicode:characters_to_binary(io_lib:format("~p", [Errors])),
            {error, <<"reloaded ", (integer_to_binary(Reloaded))/binary,
                      " modules; errors: ", Text/binary>>}
    end.

is_campy_module(Beam) ->
    string:find(Beam, "/campy_") =/= nomatch.

reload_one(Mod) ->
    _ = code:soft_purge(Mod),
    case code:load_file(Mod) of
        {module, Mod} ->
            ok;
        {error, not_purged} when Mod =:= campy_ide ->
            %% The loop process may still be in the previous version; the next
            %% iteration will switch. Try again on the following F6.
            {error, {Mod, not_purged}};
        {error, not_purged} ->
            _ = code:purge(Mod),
            case code:load_file(Mod) of
                {module, Mod} -> ok;
                {error, Reason} -> {error, {Mod, Reason}}
            end;
        {error, Reason} ->
            {error, {Mod, Reason}}
    end.
