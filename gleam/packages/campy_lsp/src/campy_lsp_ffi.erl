-module(campy_lsp_ffi).
-export([start/4, stop/1, did_open/3, did_change/4, completion/4, symbols/2,
         definition/4, format/2]).

%% ---------------------------------------------------------------------------
%% Public API (called from Gleam; Client is the client process pid)
%% ---------------------------------------------------------------------------

%% Spawn the language server, run the initialize handshake, and hand control
%% to the client loop. `Command` is {Executable, Args}, Root is the workspace
%% directory the server runs in, Master receives the projected results.
start(Language, Command, Root, Master) ->
    {Cmd, Args} = Command,
    case find_executable(Cmd) of
        false ->
            {error,
             unicode:characters_to_binary(
                 io_lib:format("~s: executable not found", [Language]))};
        CmdPath ->
            %% The client process owns the port: port data is delivered to
            %% the port owner, so the loop opens it itself at boot.
            State = #{
                language => Language,
                master => Master,
                next_id => 2,
                pending => #{},
                buffer => <<>>,
                outbox => [],
                %% Handshake: initialize is sent immediately; the outbox
                %% holds other traffic until its reply.
                ready => false
            },
            Init = request_body(
                1,
                <<"initialize">>,
                #{
                    <<"processId">> => null,
                    <<"rootUri">> => uri_of(Root),
                    <<"capabilities">> => #{}
                }
            ),
            Pid = spawn_link(
                fun() ->
                    Port = open_server(CmdPath, Args, Root),
                    client_loop(State#{port => Port})
                end
            ),
            Pid ! {send, Init},
            {ok, Pid}
    end.

stop(Client) when is_pid(Client) ->
    Client ! stop,
    nil.

did_open(Client, File, Text) ->
    Client ! {notify, <<"textDocument/didOpen">>,
              #{<<"textDocument">> =>
                    #{<<"uri">> => uri_of(File),
                      <<"languageId">> => <<"gleam">>,
                      <<"version">> => 1,
                      <<"text">> => Text}}},
    nil.

did_change(Client, File, Version, Text) ->
    Client ! {notify, <<"textDocument/didChange">>,
              #{<<"textDocument">> =>
                    #{<<"uri">> => uri_of(File), <<"version">> => Version},
                <<"contentChanges">> => [#{<<"text">> => Text}]}},
    nil.

%% Each projector closes over the document the request was made for, so the
%% projected messages are file-tagged exactly as the module header documents:
%% {lsp_completions, File, Labels}, {lsp_symbols, File, Items},
%% {lsp_definition, File, Line, Character}, {lsp_edits, File, Edits}.
completion(Client, File, Line, Character) ->
    Client ! {rpc, <<"textDocument/completion">>,
              #{<<"textDocument">> => #{<<"uri">> => uri_of(File)},
                <<"position">> => pos(Line, Character)},
              fun(Result) -> {lsp_completions, File, completion_labels(Result)} end},
    nil.

symbols(Client, File) ->
    Client ! {rpc, <<"textDocument/documentSymbol">>,
              #{<<"textDocument">> => #{<<"uri">> => uri_of(File)}},
              fun(Result) -> {lsp_symbols, File, flatten_symbols(Result)} end},
    nil.

definition(Client, File, Line, Character) ->
    Client ! {rpc, <<"textDocument/definition">>,
              #{<<"textDocument">> => #{<<"uri">> => uri_of(File)},
                <<"position">> => pos(Line, Character)},
              fun(Result) -> project_definition(File, Result) end},
    nil.

format(Client, File) ->
    Client ! {rpc, <<"textDocument/formatting">>,
              #{<<"textDocument">> => #{<<"uri">> => uri_of(File)},
                <<"options">> => #{<<"tabSize">> => 2,
                                   <<"insertSpaces">> => true}},
              fun(Result) -> {lsp_edits, File, format_edits(Result)} end},
    nil.

%% ---------------------------------------------------------------------------
%% Client process
%% ---------------------------------------------------------------------------

client_loop(State) ->
    receive
        stop ->
            catch maps:get(port, State) ! stop,
            ok;
        {send, Body} ->
            client_loop(send_now(Body, State));
        {notify, Method, Params} ->
            client_loop(gated_send(notification_body(Method, Params), State));
        {request, Method, Params} ->
            client_loop(request(State, Method, Params, none));
        {rpc, Method, Params, Projector} ->
            client_loop(request(State, Method, Params, {some, Projector}));
        {Port, {data, Bytes}} ->
            client_loop(handle_port_data(Bytes, State));
        {Port, {exit_status, Code}} ->
            Master = maps:get(master, State),
            Master ! {lsp_down,
                      unicode:characters_to_binary(
                          io_lib:format("~s exited (~p)",
                                        [maps:get(language, State), Code]))};
        _ ->
            client_loop(State)
    end.

%% Queue while the handshake is in flight; flush after the initialize reply.
send_now(Body, State = #{port := Port}) ->
    port_command(Port, frame(Body)),
    State.

%% Traffic other than the initialize request waits for the handshake reply;
%% the Gleam LS rejects anything that arrives before `initialized`.
gated_send(Body, State = #{ready := true}) ->
    send_now(Body, State);
gated_send(Body, State = #{outbox := Outbox}) ->
    State#{outbox := Outbox ++ [Body]}.

request(State, Method, Params, Projector) ->
    #{next_id := Id, pending := Pending} = State,
    Body = request_body(Id, Method, Params),
    Pending2 =
        case Projector of
            none -> Pending;
            {some, P} -> Pending#{Id => P}
        end,
    State2 = case maps:get(ready, State) of
        true -> send_now(Body, State#{next_id => Id + 1, pending := Pending2});
        false ->
            (State#{next_id => Id + 1, pending := Pending2})#{
                outbox := maps:get(outbox, State) ++ [Body]
            }
    end,
    State2.

%% ---------------------------------------------------------------------------
%% Port I/O and LSP framing
%% ---------------------------------------------------------------------------

open_server(CmdPath, Args, Root) ->
    %% The LS's stderr goes to the terminal (the LS logs its own crashes
    %% there); stdout is the LSP channel.
    open_port(
        {spawn_executable, CmdPath},
        [{args, [binary_to_list(A) || A <- Args]},
         {cd, binary_to_list(Root)},
         binary, use_stdio, exit_status, hide]).

frame(Body) when is_binary(Body) ->
    io_lib:format("Content-Length: ~b\r\n\r\n", [byte_size(Body)], []) ++ Body.

handle_port_data(Bytes, State = #{buffer := Buffer}) ->
    Buffer2 = <<Buffer/binary, Bytes/binary>>,
    case split_message(Buffer2) of
        {more, Rest} ->
            State#{buffer := Rest};
        {message, Body, Rest} ->
            State3 = handle_body(Body, State#{buffer := Rest}),
            handle_port_data(<<>>, State3)
    end.

split_message(Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Headers, Rest] ->
            case content_length(Headers) of
                {ok, Length} when byte_size(Rest) >= Length ->
                    <<Body:Length/binary, Remainder/binary>> = Rest,
                    {message, Body, Remainder};
                _ ->
                    {more, Buffer}
            end;
        _ ->
            {more, Buffer}
    end.

content_length(Headers) ->
    case re:run(Headers, "Content-Length: *(\\d+)",
                [{capture, all_but_first, list}, caseless]) of
        {match, [Length]} -> {ok, list_to_integer(Length)};
        _ -> error
    end.

handle_body(Body, State) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            case maps:find(<<"id">>, Map) of
                {ok, Id} when is_integer(Id) ->
                    handle_response(Id, Map, State);
                {ok, Id} when is_binary(Id); is_atom(Id) ->
                    %% A server -> client request (e.g.
                    %% window/workDoneProgress/create): the client must
                    %% answer, or the server stalls waiting for it.
                    _ = reply_to_server(State, Id),
                    handle_notification(Map, State);
                _ ->
                    handle_notification(Map, State)
            end;
        _ ->
            State
    catch
        _:_ ->
            State
    end.

reply_to_server(State = #{port := Port}, Id) ->
    port_command(
        Port,
        frame(
            iolist_to_binary(
                json:encode(
                    #{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> =>
                            case Id of
                                A when is_atom(A) -> atom_to_binary(A, utf8);
                                B when is_binary(B) -> B
                            end,
                        <<"result">> => null
                    }
                )
            )
        )
    ),
    ok.

handle_response(1, Map, State = #{port := Port, outbox := Outbox}) ->
    %% Initialize reply: the server is ready; announce it and flush the
    %% queued traffic.
    port_command(
        Port,
        frame(
            iolist_to_binary(
                json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"initialized">>,
                              <<"params">> => #{}})
            )
        )
    ),
    lists:foldl(
        fun(Body, St) -> send_now(Body, St) end,
        State#{ready := true, outbox := []},
        Outbox
    );
handle_response(Id, Map, State = #{pending := Pending, master := Master}) ->
    Projector = maps:get(Id, Pending, none),
    State2 = State#{pending := maps:remove(Id, Pending)},
    case maps:find(<<"result">>, Map) of
        {ok, Result} ->
            case Projector of
                none -> ok;
                Fun when is_function(Fun) -> Master ! Fun(Result);
                _ -> ok
            end;
        _ ->
            ok
    end,
    State2.

handle_notification(Map = #{<<"method">> := <<"textDocument/publishDiagnostics">>}, State) ->
    Master = maps:get(master, State),
    Params = maps:get(<<"params">>, Map),
    File = strip_uri(maps:get(<<"uri">>, Params, <<>>)),
    Diags = maps:get(<<"diagnostics">>, Params, []),
    Rows =
        [begin
             Start = maps:get(<<"start">>, Range),
             End = maps:get(<<"end">>, Range),
             {maps:get(<<"line">>, Start, 0),
              maps:get(<<"line">>, End, 0),
              maps:get(<<"message">>, D, <<>>),
              maps:get(<<"severity">>, D, 3)}
         end
         || D <- Diags, is_map(D),
            Range <- [maps:get(<<"range">>, D, #{<<"start">> => #{}, <<"end">> => #{}})],
            is_map(Range)],
    Master ! {lsp_diagnostics, File, Rows},
    State;
handle_notification(_Map, State) ->
    State.

%% ---------------------------------------------------------------------------
%% Projections (server result -> master message)
%% ---------------------------------------------------------------------------

pos(Line, Character) ->
    #{<<"line">> => Line, <<"character">> => Character}.

completion_labels(Result) ->
    Items =
        case Result of
            #{<<"items">> := Items0} when is_list(Items0) -> Items0;
            Items0 when is_list(Items0) -> Items0;
            _ -> []
        end,
    [Label
     || Item <- Items, is_map(Item),
        Label <- [maps:get(<<"label">>, Item, none)], is_binary(Label)].


%% Flatten hierarchical DocumentSymbol[] / flat SymbolInformation[].
project_symbols(Result) ->
    {lsp_symbols, flatten_symbols(Result)}.

flatten_symbols(Symbols) when is_list(Symbols) ->
    lists:flatmap(fun flatten_symbol/1, Symbols);
flatten_symbols(_) ->
    [].

flatten_symbol(#{<<"selectionRange">> := Range, <<"name">> := Name} = Symbol)
    when is_map(Range), is_binary(Name) ->
    Start = maps:get(<<"start">>, Range, #{}),
    Line = maps:get(<<"line">>, Start, 0),
    Children = flatten_symbols(maps:get(<<"children">>, Symbol, [])),
    [{Name, Line} | Children];
flatten_symbol(#{<<"location">> := Location, <<"name">> := Name})
    when is_map(Location), is_binary(Name) ->
    Range = maps:get(<<"range">>, Location, #{}),
    Start = maps:get(<<"start">>, Range, #{}),
    [{Name, maps:get(<<"line">>, Start, 0)}];
flatten_symbol(_) ->
    [].

project_definition(_File, Result) ->
    Location =
        case Result of
            [First | _] when is_map(First) -> First;
            #{<<"uri">> := _} = L -> L;
            null -> none;
            _ -> none
        end,
    case Location of
        #{<<"uri">> := Uri, <<"range">> := Range} ->
            Start = maps:get(<<"start">>, Range, #{}),
            %% The reply's uri is where the declaration lives, which may be a
            %% different document than the one the request named.
            {lsp_definition, strip_uri(Uri),
             maps:get(<<"line">>, Start, 0),
             maps:get(<<"character">>, Start, 0)};
        _ ->
            {lsp_no_definition}
    end.

%% Formatting returns TextEdit[]; project to per-line replacements.
format_edits(Result) when is_list(Result) ->
    [begin
         Start = maps:get(<<"start">>, maps:get(<<"range">>, Edit, #{}), #{}),
         {maps:get(<<"line">>, Start, 0),
          maps:get(<<"newText">>, Edit, <<>>)}
     end
     || Edit <- Result, is_map(Edit)];
format_edits(_) ->
    [].

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% A notification carries no id, per LSP.
notification_body(Method, Params) ->
    iolist_to_binary(
        json:encode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => Method,
            <<"params">> => Params
        })
    ).

request_body(Id, Method, Params) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => case Id of none -> null; _ -> Id end,
        <<"method">> => Method,
        <<"params">> => Params
    }),
    iolist_to_binary(Body).

find_executable(Cmd) ->
    case os:find_executable(binary_to_list(Cmd)) of
        false -> false;
        Path -> unicode:characters_to_binary(Path)
    end.

uri_of(File) when is_binary(File) ->
    <<"file://", File/binary>>.

strip_uri(Uri) when is_binary(Uri) ->
    case Uri of
        <<"file://", Rest/binary>> -> Rest;
        Other -> Other
    end.
