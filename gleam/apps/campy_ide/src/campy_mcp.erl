-module(campy_mcp).
-export([start/1, stop/0, status/0, next_request/0, reply/3, test_handle/1, test_post/2]).

-define(SERVER, campy_mcp_server).
-define(REQUESTS, campy_mcp_requests).
-define(META, campy_mcp_meta).

%% Minimal MCP server over streamable HTTP on localhost. The IDE loop is the
%% owner: tool calls are forwarded to it as {campy_mcp, From, Ref, Tool, Arg}.
start(Port) ->
    _ = stop(),
    catch ets:new(?REQUESTS, [named_table, public, set]),
    Parent = self(),
    Owner = self(),
    Pid = spawn(fun() -> init(Port, Owner, Parent) end),
    receive
        {Pid, started} ->
            try register(?SERVER, Pid) of
                true -> {ok, nil}
            catch
                _:_ -> {error, <<"MCP server is already registered">>}
            end;
        {Pid, {error, Reason}} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    after 3000 ->
        exit(Pid, kill),
        {error, <<"MCP server start timed out">>}
    end.

stop() ->
    case whereis(?SERVER) of
        undefined ->
            {ok, nil};
        Pid ->
            Pid ! {stop, self()},
            receive
                {Pid, stopped} -> {ok, nil}
            after 2000 ->
                exit(Pid, kill),
                {ok, nil}
            end
    end.

status() ->
    case whereis(?SERVER) of
        undefined ->
            <<"Stopped">>;
        _ ->
            case catch ets:lookup(?META, port) of
                [{port, Port}] ->
                    iolist_to_binary(io_lib:format(
                        "Listening on http://127.0.0.1:~p/mcp", [Port]));
                _ ->
                    <<"Listening">>
            end
    end.

%% Called from the IDE loop. Returns {some, {Handle, Tool, Arg}} or none.
next_request() ->
    catch ets:new(?REQUESTS, [named_table, public, set]),
    receive
        {campy_mcp, From, Ref, Tool, Arg} ->
            Handle = erlang:unique_integer([positive, monotonic]),
            ets:insert(?REQUESTS, {Handle, From, Ref}),
            {some, {Handle, Tool, Arg}}
    after 0 ->
        none
    end.

reply(Handle, Text, IsError) ->
    case catch ets:lookup(?REQUESTS, Handle) of
        [{Handle, From, Ref}] ->
            ets:delete(?REQUESTS, Handle),
            From ! {Ref, Text, IsError},
            nil;
        _ ->
            {error, <<"unknown MCP request">>}
    end.

%% Pure protocol entry point used by tests (initialize / tools/list do not need
%% a live IDE owner).
test_handle(Body) ->
    {_Code, Response} = handle(iolist_to_binary(Body), self()),
    Response.

test_post(Port, Body) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 3000) of
        {ok, Socket} ->
            Request = [
                <<"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n">>,
                <<"Content-Type: application/json\r\nContent-Length: ">>,
                integer_to_binary(byte_size(Body)),
                <<"\r\nConnection: close\r\n\r\n">>,
                Body
            ],
            ok = gen_tcp:send(Socket, Request),
            Response = recv_all(Socket, <<>>),
            gen_tcp:close(Socket),
            Response;
        {error, Reason} ->
            iolist_to_binary(io_lib:format("connect error: ~p", [Reason]))
    end.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% ---------------------------------------------------------------------------
%% HTTP transport
%% ---------------------------------------------------------------------------

init(Port, Owner, Parent) ->
    catch ets:new(?META, [named_table, public, set]),
    Options = [binary, {ip, {127, 0, 0, 1}}, {packet, raw}, {active, false},
               {reuseaddr, true}],
    case gen_tcp:listen(Port, Options) of
        {ok, Listen} ->
            ets:insert(?META, {port, Port}),
            Parent ! {self(), started},
            accept(Listen, Owner);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept(Listen, Owner) ->
    receive
        {stop, From} ->
            catch gen_tcp:close(Listen),
            catch ets:delete(?META),
            From ! {self(), stopped},
            ok
    after 0 ->
        case gen_tcp:accept(Listen, 500) of
            {ok, Socket} ->
                spawn(fun() -> serve(Socket, Owner) end),
                accept(Listen, Owner);
            {error, timeout} ->
                accept(Listen, Owner);
            {error, closed} ->
                ok;
            {error, _} ->
                accept(Listen, Owner)
        end
    end.

serve(Socket, Owner) ->
    try
        case read_request(Socket) of
            {ok, <<"POST">>, Body} ->
                case handle(Body, Owner) of
                    {202, _} ->
                        respond(Socket, 202, <<>>, <<"text/plain">>);
                    {Code, Response} ->
                        respond(Socket, Code, Response, <<"application/json">>)
                end;
            {ok, _Method, _Body} ->
                respond(Socket, 405, <<"Method Not Allowed">>, <<"text/plain">>);
            {error, _} ->
                respond(Socket, 400, <<"Bad Request">>, <<"text/plain">>)
        end
    catch
        _:_ ->
            catch respond(Socket, 500, <<"Internal error">>, <<"text/plain">>)
    after
        catch gen_tcp:close(Socket)
    end.

read_request(Socket) ->
    case read_headers(Socket, <<>>) of
        {ok, Head, Rest} ->
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            case Lines of
                [RequestLine | HeaderLines] ->
                    case binary:split(RequestLine, <<" ">>, [global]) of
                        [Method, Path, _Version] ->
                            case path_only(Path) of
                                <<"/mcp">> ->
                                    case content_length(HeaderLines) of
                                        {ok, Length} ->
                                            Body = read_body(Socket, Rest, Length),
                                            {ok, Method, Body};
                                        error ->
                                            {ok, Method, <<>>}
                                    end;
                                _ ->
                                    {error, not_found}
                            end;
                        _ ->
                            {error, bad_request}
                    end;
                _ ->
                    {error, bad_request}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

path_only(Path) ->
    case binary:split(Path, <<"?">>) of
        [Only | _] -> Only;
        [] -> Path
    end.

read_headers(Socket, Acc) when byte_size(Acc) > 65536 ->
    {error, headers_too_large};
read_headers(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            {ok, Head, Rest};
        [_] ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} ->
                    read_headers(Socket, <<Acc/binary, Data/binary>>);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

content_length(HeaderLines) ->
    lists:foldl(
        fun(Line, Acc) ->
            case binary:split(Line, <<":">>) of
                [Name, Value] ->
                    case lower(trim(Name)) of
                        <<"content-length">> ->
                            try {ok, binary_to_integer(trim(Value))}
                            catch _:_ -> error end;
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end
        end,
        error,
        HeaderLines
    ).

read_body(_Socket, Rest, 0) ->
    binary:part(Rest, 0, 0);
read_body(_Socket, Rest, Length) when byte_size(Rest) >= Length ->
    binary:part(Rest, 0, Length);
read_body(Socket, Rest, Length) ->
    Wanted = Length - byte_size(Rest),
    case gen_tcp:recv(Socket, Wanted, 5000) of
        {ok, More} -> <<Rest/binary, More/binary>>;
        {error, _} -> Rest
    end.

respond(Socket, Code, Body, ContentType) ->
    Status = status_text(Code),
    Length = integer_to_binary(iolist_size(Body)),
    Head = [
        <<"HTTP/1.1 ">>, Status,
        <<"\r\nContent-Type: ">>, ContentType,
        <<"\r\nContent-Length: ">>, Length,
        <<"\r\nAccess-Control-Allow-Origin: *">>,
        <<"\r\nConnection: close\r\n\r\n">>
    ],
    gen_tcp:send(Socket, [Head, Body]),
    ok.

status_text(200) -> <<"200 OK">>;
status_text(202) -> <<"202 Accepted">>;
status_text(400) -> <<"400 Bad Request">>;
status_text(404) -> <<"404 Not Found">>;
status_text(405) -> <<"405 Method Not Allowed">>;
status_text(500) -> <<"500 Internal Server Error">>;
status_text(_) -> <<"200 OK">>.

%% ---------------------------------------------------------------------------
%% JSON-RPC / MCP
%% ---------------------------------------------------------------------------

handle(Body, Owner) ->
    try json:decode(Body) of
        Message when is_map(Message) ->
            handle_message(Message, Owner);
        _ ->
            {200, error_body(null, -32600, <<"Invalid Request">>)}
    catch
        _:_ ->
            {200, error_body(null, -32700, <<"Parse error">>)}
    end.

handle_message(Message, Owner) ->
    Id = maps:get(<<"id">>, Message, null),
    Method = maps:get(<<"method">>, Message, undefined),
    case Method of
        <<"initialize">> ->
            json_result(Id, initialize_result());
        <<"notifications/initialized">> ->
            {202, <<>>};
        <<"notifications/cancelled">> ->
            {202, <<>>};
        <<"ping">> ->
            json_result(Id, #{});
        <<"tools/list">> ->
            json_result(Id, #{<<"tools">> => tools()});
        <<"tools/call">> ->
            tool_call(Id, maps:get(<<"params">>, Message, #{}), Owner);
        _ ->
            case Id of
                null -> {202, <<>>};
                _ -> {200, error_body(Id, -32601, <<"Method not found">>)}
            end
    end.

initialize_result() ->
    #{
        <<"protocolVersion">> => <<"2024-11-05">>,
        <<"capabilities">> => #{<<"tools">> => #{}},
        <<"serverInfo">> => #{<<"name">> => <<"campy">>, <<"version">> => <<"0.1.0">>}
    }.

tool_call(Id, Params, Owner) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    case tool_arg(Name, Args) of
        {ok, Tool, Arg} ->
            Ref = make_ref(),
            Owner ! {campy_mcp, self(), Ref, Tool, Arg},
            receive
                {Ref, Text, IsError} ->
                    TextBin = unicode:characters_to_binary(Text),
                    json_result(Id, tool_result(TextBin, IsError))
            after 30000 ->
                json_result(Id, tool_result(<<"MCP tool timed out">>, true))
            end;
        {error, Message} ->
            json_result(Id, tool_result(Message, true))
    end.

tool_result(Text, IsError) ->
    #{
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => Text}],
        <<"isError">> => IsError
    }.

tool_arg(<<"campy_status">>, _Args) -> {ok, <<"status">>, <<>>};
tool_arg(<<"campy_modules">>, _Args) -> {ok, <<"modules">>, <<>>};
tool_arg(<<"campy_form">>, _Args) -> {ok, <<"form">>, <<>>};
tool_arg(<<"campy_console">>, _Args) -> {ok, <<"console">>, <<>>};
tool_arg(<<"campy_run">>, _Args) -> {ok, <<"run">>, <<>>};
tool_arg(<<"campy_stop">>, _Args) -> {ok, <<"stop">>, <<>>};
tool_arg(<<"campy_update_app">>, _Args) -> {ok, <<"update_app">>, <<>>};
tool_arg(<<"campy_select_control">>, Args) ->
    case maps:get(<<"id">>, Args, undefined) of
        undefined -> {error, <<"id is required">>};
        Id -> {ok, <<"select">>, to_binary(Id)}
    end;
tool_arg(<<"campy_send_input">>, Args) ->
    case maps:get(<<"text">>, Args, undefined) of
        undefined -> {error, <<"text is required">>};
        Text -> {ok, <<"send_input">>, to_binary(Text)}
    end;
tool_arg(<<"campy_set_control">>, Args) ->
    case {maps:get(<<"id">>, Args, undefined),
          maps:get(<<"field">>, Args, undefined),
          maps:get(<<"value">>, Args, undefined)} of
        {undefined, _, _} -> {error, <<"id is required">>};
        {_, undefined, _} -> {error, <<"field is required">>};
        {_, _, undefined} -> {error, <<"value is required">>};
        {Id, Field, Value} ->
            Arg = <<(to_binary(Id))/binary, "\t", (to_binary(Field))/binary, "\t",
                    (to_binary(Value))/binary>>,
            {ok, <<"set_field">>, Arg}
    end;
tool_arg(Name, _Args) ->
    {error, <<"Unknown tool: ", Name/binary>>}.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_float(Value) -> float_to_binary(Value, [{decimals, 0}, compact]);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(true) -> <<"true">>;
to_binary(false) -> <<"false">>;
to_binary(null) -> <<>>;
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

tools() ->
    [
        tool(<<"campy_status">>, <<"Current workspace, project, module, selection and status.">>, #{}),
        tool(<<"campy_modules">>, <<"List the active project's modules.">>, #{}),
        tool(<<"campy_form">>, <<"Describe the active module's form and controls.">>, #{}),
        tool(<<"campy_console">>, <<"Read the application console output.">>, #{}),
        tool(<<"campy_run">>, <<"Run the active module in the app preview.">>, #{}),
        tool(<<"campy_stop">>, <<"Stop the app preview.">>, #{}),
        tool(<<"campy_update_app">>, <<"Update the running app preview (F7).">>, #{}),
        tool(<<"campy_select_control">>, <<"Select a control by id.">>,
             #{<<"id">> => #{<<"type">> => <<"string">>}}),
        tool(<<"campy_set_control">>, <<"Set a control field (text, x, y, w, h or name).">>,
             #{<<"id">> => #{<<"type">> => <<"string">>},
               <<"field">> => #{<<"type">> => <<"string">>},
               <<"value">> => #{}}),
        tool(<<"campy_send_input">>, <<"Send a line to the running app console.">>,
             #{<<"text">> => #{<<"type">> => <<"string">>}})
    ].

tool(Name, Description, Properties) ->
    Required = maps:keys(Properties),
    Schema =
        case maps:size(Properties) of
            0 -> #{<<"type">> => <<"object">>, <<"properties">> => #{}};
            _ -> #{<<"type">> => <<"object">>, <<"properties">> => Properties,
                   <<"required">> => Required}
        end,
    #{<<"name">> => Name, <<"description">> => Description,
      <<"inputSchema">> => Schema}.

json_result(Id, Result) ->
    {200, iolist_to_binary(json:encode(
        #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result}))}.

error_body(Id, Code, Message) ->
    iolist_to_binary(json:encode(
        #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
          <<"error">> => #{<<"code">> => Code, <<"message">> => Message}})).

lower(Value) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Value))).

trim(Value) ->
    unicode:characters_to_binary(string:trim(unicode:characters_to_list(Value))).
