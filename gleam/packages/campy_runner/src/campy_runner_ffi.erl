-module(campy_runner_ffi).
-export([install/1, loaded_versions/0, init_of/1, purge/1, beams_of_dir/1, unlink_owner/1]).

%% Load compiled beams in order; the first failure aborts.
install(Beams) ->
    install(Beams, 0).

install([], Count) ->
    {ok, Count};
install([{Module, Binary} | Rest], Count) when is_binary(Module) ->
    try code:load_binary(binary_to_atom(Module, utf8), <<>>, Binary) of
        {module, _} -> install(Rest, Count + 1);
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("load ~s: ~p", [Module, Reason]))}
    catch
        _:Fail:_ -> {error, format("load ~s: ~p", [Module, Fail])}
    end;
install([Other | _], _) ->
    {error, format("bad beam entry ~p", [Other])}.

%% The code version of every loaded campy module, for the node manager.
loaded_versions() ->
    [
        {atom_to_binary(M, utf8),
         unicode:characters_to_binary(io_lib:format("~p", [V]))}
     || {M, V, _} <- code:all_loaded(),
        M =/= undefined,
        begin
            Name = atom_to_binary(M, utf8),
            case binary:part(Name, 0, min(byte_size(Name), 6)) of
                <<"campy_">> -> true;
                _ -> false
            end
        end
    ].

%% The actor links to its starter; an rpc caller is transient, so unlink the
%% actor from the caller pid before returning.
unlink_owner(Subject) when is_tuple(Subject), element(1, Subject) =:= subject ->
    Pid = element(2, Subject),
    catch erlang:unlink(Pid),
    nil;
unlink_owner(_) ->
    nil.

%% init/0 of an installed app module, contained.
init_of(Module) ->
    try erlang:apply(mod(Module), init, []) of State -> {ok, State}
    catch Class:Fail:Stack ->
        {error, format("~p: ~p~n~p", [Class, Fail, Stack])}
    end.

purge(Module) ->
    Atom = mod(Module),
    case code:is_loaded(Atom) of
        {file, _} ->
            code:purge(Atom),
            code:delete(Atom),
            nil;
        false ->
            nil
    end.

%% All beams in a directory as #(module_name, binary) pairs, sorted by name.
beams_of_dir(Dir) ->
    Files = filelib:wildcard(
        unicode:characters_to_list(Dir) ++ "/*.beam"),
    lists:sort(
        lists:filtermap(
            fun(Path) ->
                Module = filename:basename(Path, ".beam"),
                case file:read_file(Path) of
                    {ok, Binary} ->
                        {true,
                         {unicode:characters_to_binary(Module), Binary}};
                    {error, _} -> false
                end
            end,
            Files)).

mod(Name) when is_binary(Name) -> binary_to_atom(Name, utf8);
mod(Name) when is_atom(Name) -> Name.

format(Template, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Template, Arguments)).
