-module(campy_view_ffi).
-export([decode/1]).

%% Decode JSON into the term shape of campy_view/codec.Json. The atom tags
%% mirror Gleam's compiled constructor names (j_object, j_int, ...).

decode(Input) ->
    try
        Term = json:decode(Input),
        {ok, to_gleam(Term)}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(
                io_lib:format("invalid JSON: ~ts", [shorten(Reason)]))}
    end.

to_gleam(Map) when is_map(Map) ->
    {j_object, [{Key, to_gleam(Value)} || {Key, Value} <- maps:to_list(Map)]};
to_gleam(List) when is_list(List) ->
    {j_array, [to_gleam(Item) || Item <- List]};
to_gleam(true) -> {j_bool, true};
to_gleam(false) -> {j_bool, false};
to_gleam(null) -> j_null;
to_gleam(Number) when is_integer(Number) -> {j_int, Number};
to_gleam(Number) when is_float(Number) -> {j_float, Number};
to_gleam(Binary) when is_binary(Binary) -> {j_string, Binary}.

shorten(Term) ->
    Text = lists:flatten(io_lib:format("~p", [Term])),
    case length(Text) > 200 of
        true -> lists:sublist(Text, 200) ++ "...";
        false -> Text
    end.
