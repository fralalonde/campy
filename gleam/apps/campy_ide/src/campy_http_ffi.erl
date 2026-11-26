-module(campy_http_ffi).
-export([read/1]).

%% A datasource reads its content: an http(s) URL goes through inets, anything
%% else is a path (relative to CAMPY_ROOT, like every other project path).
read(Url) ->
    case unicode:characters_to_list(Url) of
        [$h, $t, $t, $p | _] -> fetch(unicode:characters_to_list(Url));
        Path -> read_file(Path)
    end.

fetch(Url) ->
    case {application:ensure_all_started(inets),
          application:ensure_all_started(ssl)} of
        {{ok, _}, {ok, _}} ->
            Request = httpc:request(get, {Url, []},
                                    [{timeout, 5000}, {connect_timeout, 3000}],
                                    [{body_format, binary}]),
            case Request of
                {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
                {ok, {{_, Code, _}, _, _}} -> {error, integer_to_binary(Code)};
                {error, Reason} -> {error, fmt(Reason)}
            end;
        {Started, _} -> {error, fmt(Started)}
    end.

read_file(Path) ->
    Full = case filename:pathtype(Path) of
        absolute -> Path;
        _ -> filename:join(root(), Path)
    end,
    case file:read_file(Full) of
        {ok, Binary} -> {ok, Binary};
        {error, Reason} -> {error, fmt(Reason)}
    end.

root() ->
    case os:getenv("CAMPY_ROOT") of
        false -> ".";
        Value -> Value
    end.

fmt(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).
