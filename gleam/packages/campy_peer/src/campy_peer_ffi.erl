-module(campy_peer_ffi).
-export([start/1, stop/1, call/4, ping/1, start_distribution/1, this_node/0, deploy_dir/2]).

%% peer:start(#{name => Name@Host}) -> {ok, Pid, Node}.
%% The peer option `name` is the full node name; build it from the local
%% host (`net_adm:localhost/0`) with shortnames semantics.
start(Name) when is_binary(Name) ->
    Full = unicode:characters_to_list(Name) ++ "@" ++ net_adm:localhost(),
    Cookie =
        case erlang:get_cookie() of
            NoCookie when NoCookie =:= nocookie; NoCookie =:= undefined ->
                campy;
            Cookie0 -> Cookie0
        end,
    true = erlang:set_cookie(node(), Cookie),
    true = erlang:set_cookie(list_to_atom(Full), Cookie),
    try peer:start(#{name => list_to_atom(Full), cookie => Cookie}) of
        {ok, Pid, Node} ->
            {ok, {Pid, atom_to_binary(Node, utf8)}};
        {error, Reason} ->
            {error, format("~p", [Reason])}
    catch
        Class:Fail:Stack -> {error, format("~p: ~p~n~p", [Class, Fail, Stack])}
    end;
start(Name) ->
    {error, format("bad name ~p", [Name])}.

stop(Pid) ->
    peer:stop(Pid),
    nil.

%% Calls go over Erlang distribution (rpc); `peer:call` would need the
%% optional port-based alternative connection, which we do not configure.
%% Module/function arrive as binaries; the call runs with a timeout.
call(Node, Module, Function, Args) ->
    Result = rpc:call(node_name(Node), mod(Module), funname(Function), Args, 5000),
    case Result of
        {badrpc, Reason} -> {error, format("~p", [Reason])};
        Other -> {ok, Other}
    end.

%% A cheap round trip: the peer's own node name. The peer's net kernel needs
%% a moment after boot before rpc connections are accepted, so the first call
%% waits for it (up to ~2 s).
ping(Node) ->
    wait_peer(Node, 10).

wait_peer(_Node, 0) ->
    {error, <<"noconnection">>};
wait_peer(Node, Attempts) ->
    case rpc:call(node_name(Node), erlang, node, [], 5000) of
        Peer when is_atom(Peer) -> {ok, atom_to_binary(Peer, utf8)};
        _ ->
            timer:sleep(200),
            wait_peer(Node, Attempts - 1)
    end.

%% Start net kernel distribution with a short name. When distribution is
%% already on, report the existing name instead of failing.
start_distribution(Name) when is_binary(Name) ->
    case erlang:is_alive() of
        true ->
            {ok, nil};
        false ->
            ensure_epmd(),
            case net_kernel:start([binary_to_atom(Name, utf8), shortnames]) of
                {ok, _} -> {ok, nil};
                {error, Reason} -> {error, format("~p", [Reason])}
            end
    end;
start_distribution(_) ->
    {error, <<"bad name">>}.

%% erl only starts epmd when the node itself is distributed; a runtime
%% net_kernel:start needs it running already.
ensure_epmd() ->
    case net_adm:names() of
        {ok, _} ->
            ok;
        {error, _} ->
            os:cmd("epmd -daemon"),
            timer:sleep(200),
            ok
    end.

this_node() ->
    case erlang:is_alive() of
        true -> atom_to_binary(node(), utf8);
        false -> <<>>
    end.

mod(Name) when is_binary(Name) -> binary_to_atom(Name, utf8);
mod(Name) when is_atom(Name) -> Name.

funname(Name) when is_binary(Name) -> binary_to_atom(Name, utf8);
funname(Name) when is_atom(Name) -> Name.

node_name(Node) when is_binary(Node) -> binary_to_atom(Node, utf8);
node_name(Node) when is_atom(Node) -> Node.

%% IDE-side deploy: read every beam under a local directory and load it on
%% the remote node with code:load_binary (the bootstrap transport before the
%% runner itself is installed). Returns the number of modules loaded.
deploy_dir(Node, Dir) ->
    Files = filelib:wildcard(unicode:characters_to_list(Dir) ++ "/*.beam"),
    deploy_files(node_name(Node), lists:sort(Files), 0).

deploy_files(_Node, [], Count) ->
    {ok, Count};
deploy_files(Node, [Path | Rest], Count) ->
    Module = list_to_atom(filename:basename(Path, ".beam")),
    case file:read_file(Path) of
        {ok, Binary} ->
            case rpc:call(Node, code, load_binary, [Module, Path, Binary], 10000) of
                {module, _} ->
                    deploy_files(Node, Rest, Count + 1);
                {badrpc, Reason} ->
                    {error, format("~s: badrpc ~p", [Path, Reason])};
                {error, Reason} ->
                    {error, format("~s: ~p", [Path, Reason])}
            end;
        {error, Reason} ->
            {error, format("read ~s: ~p", [Path, Reason])}
    end.

format(Template, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Template, Arguments)).
