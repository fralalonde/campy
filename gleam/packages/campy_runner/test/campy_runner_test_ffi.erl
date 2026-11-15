-module(campy_runner_test_ffi).
-export([remove_tree/1, write_file/2, which/1, make_fixture_module/2,
         reset_order/0, order/0, note/1, unload/1, file_exists/1]).

remove_tree(Path) ->
    case file:del_dir_r(unicode:characters_to_list(Path)) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                io_lib:format("cannot remove ~ts: ~p", [Path, Reason]))}
    end.

write_file(Path, Contents) ->
    Native = unicode:characters_to_list(Path),
    case filelib:ensure_dir(Native) of
        ok ->
            case file:write_file(Native, Contents) of
                ok -> {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("cannot write ~ts: ~p", [Path, Reason]))}
            end;
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                io_lib:format("cannot create ~ts: ~p", [Path, Reason]))}
    end.

file_exists(Path) ->
    filelib:is_file(unicode:characters_to_list(Path)).

which(ModuleBin) ->
    case code:which(binary_to_atom(ModuleBin, utf8)) of
        Path when is_list(Path) -> unicode:characters_to_binary(Path);
        Other -> unicode:characters_to_binary(io_lib:format("~p", [Other]))
    end.

%% Compile a tiny module whose on_load records this module's name. The test
%% loads two such modules through campy_runner_ffi and checks the order.
make_fixture_module(Dir, ModuleBin) ->
    Module = binary_to_atom(ModuleBin, utf8),
    Path = filename:join(unicode:characters_to_list(Dir),
                         atom_to_list(Module) ++ ".beam"),
    Forms = [
        {attribute, 1, module, Module},
        {attribute, 1, export, [{on_load, 0}]},
        {attribute, 1, on_load, {on_load, 0}},
        {function, 1, on_load, 0, [{clause, 1, [], [], [
            {call, 1,
             {remote, 1,
              {atom, 1, campy_runner_test_ffi},
              {atom, 1, note}},
             [{atom, 1, Module}]}
        ]}]}
    ],
    case compile:forms(Forms, [binary, return_errors]) of
        {ok, Module, Beam} ->
            case filelib:ensure_dir(Path) of
                ok ->
                    case file:write_file(Path, Beam) of
                        ok -> {ok, nil};
                        {error, Reason} ->
                            {error, unicode:characters_to_binary(
                                io_lib:format("cannot write ~ts: ~p",
                                              [Path, Reason]))}
                    end;
                {error, Reason} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("cannot create ~ts: ~p",
                                      [Path, Reason]))}
            end;
        {ok, Module, Beam, _Warnings} ->
            _ = filelib:ensure_dir(Path),
            case file:write_file(Path, Beam) of
                ok -> {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("cannot write ~ts: ~p", [Path, Reason]))}
            end;
        {error, Errors, _Warnings} ->
            {error, unicode:characters_to_binary(
                io_lib:format("cannot compile ~ts: ~p", [ModuleBin, Errors]))}
    end.

reset_order() ->
    case ets:whereis(campy_runner_order) of
        undefined -> ok;
        _ -> ets:delete(campy_runner_order)
    end,
    _ = ets:new(campy_runner_order, [named_table, public, set]),
    nil.

note(Module) ->
    _ = ets:insert(campy_runner_order,
                   {erlang:unique_integer([monotonic, positive]), Module}),
    ok.

order() ->
    case ets:whereis(campy_runner_order) of
        undefined ->
            [];
        _ ->
            [atom_to_binary(Module, utf8)
             || {_Key, Module} <- lists:keysort(1, ets:tab2list(campy_runner_order))]
    end.

unload(ModuleBin) ->
    Module = binary_to_atom(ModuleBin, utf8),
    _ = code:delete(Module),
    _ = code:purge(Module),
    nil.
