-module(campy_runner_ffi).
-export([install/1, loaded_versions/0, init_of/1, purge/1, beams_of_dir/1, unlink_owner/1, processes/0, tracer_loop/2]).

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

%% User processes for the debug page: pids, reductions, message queue and
%% initial call. System/OTP processes are filtered out by registered name and
%% initial call.
processes() ->
    %% Gleam actors run under proc_lib, whose raw initial_call is
    %% proc_lib:init_p/3; the real one is in the $initial_call dictionary key.
    lists:filtermap(
        fun(P) ->
            case process_info(P, registered_name) of
                [] ->
                    {reductions, R} = process_info(P, reductions),
                    {message_queue_len, Q} = process_info(P, message_queue_len),
                    Initial =
                        case process_info(P, dictionary) of
                            {dictionary, Dict} ->
                                case lists:keyfind('$initial_call', 1, Dict) of
                                    {_, IC} -> IC;
                                    false ->
                                        {initial_call, IC0} =
                                            process_info(P, initial_call),
                                        IC0
                                end;
                            _ ->
                                {initial_call, IC1} =
                                    process_info(P, initial_call),
                                IC1
                        end,
                    {M, _, _} = Initial,
                    Name = atom_to_binary(M, utf8),
                    Head = binary:part(Name, 0, min(byte_size(Name), 6)),
                    case Head of
                        <<"campy_">> ->
                            {true,
                             {format("~p", [P]),
                              R,
                              Q,
                              unicode:characters_to_binary(
                                  io_lib:format("~p", [Initial]))}};
                        <<"gleam@">> ->
                            {true,
                             {format("~p", [P]),
                              R,
                              Q,
                              unicode:characters_to_binary(
                                  io_lib:format("~p", [Initial]))}};
                        _ ->
                            false
                    end;
                _ ->
                    false
            end
        end,
        erlang:processes()).

%% The send/receive tracer for the debug page. It runs ON the peer (erlang:trace
%% accepts only local tracers) and forwards formatted lines to the master pid
%% on the IDE node, where they surface as {trace_log, Text} messages.
tracer_loop(Master, Label) ->
    Master ! {trace_log,
              unicode:characters_to_binary(
                  io_lib:format("~s tracer alive on ~p", [Label, node()]))},
    tracer_loop2(Master, Label).

tracer_loop2(Master, Label) ->
    receive
        stop ->
            Master ! {trace_log, <<"[trace] stopped">>};
        {trace, _Pid, send, Msg, To} ->
            Master ! {trace_log,
                      unicode:characters_to_binary(
                          io_lib:format("~s send ~p -> ~p", [Label, Msg, To]))},
            tracer_loop(Master, Label);
        {trace, _Pid, 'receive', Msg} ->
            Master ! {trace_log,
                      unicode:characters_to_binary(
                          io_lib:format("~s receive ~p", [Label, Msg]))},
            tracer_loop(Master, Label);
        {trace, _Pid, Event, _Info} ->
            Master ! {trace_log,
                      unicode:characters_to_binary(
                          io_lib:format("~s ~p", [Label, Event]))},
            tracer_loop(Master, Label);
        _ ->
            tracer_loop(Master, Label)
    end.

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
