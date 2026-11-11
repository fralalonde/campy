-module(campy_host_ffi).
-export([watch_enabled/0, signal/0, wait/0, reload_search_box/0,
         describe_search_box/0, write_generated/1, generated_path/1,
         headless_enabled/0, now_ms/0]).

headless_enabled() -> os:getenv("CAMPY_HEADLESS") =:= "1".
now_ms() -> erlang:monotonic_time(millisecond).

watch_enabled() -> os:getenv("CAMPY_WATCH") =:= "1".

signal() ->
    case os:getenv("CAMPY_RELOAD_SIGNAL") of
        false -> <<>>;
        Path -> case file:read_file(Path) of {ok, Bytes} -> Bytes; _ -> <<>> end
    end.

wait() -> receive after 250 -> nil end.

%% The MVP reload boundary is exactly one module with an unchanged public ABI.
%% No captured callbacks from that module are kept in the host.
reload_search_box() ->
    Module = campy_search_box,
    case code:soft_purge(Module) of
        false -> {error, <<"Old search-box code is still in use; restart required">>};
        true ->
            case code:get_object_code(Module) of
                {Module, Binary, Filename} ->
                    case code:load_binary(Module, Filename, Binary) of
                        {module, Module} -> {ok, nil};
                        {error, Reason} -> error_text(Reason)
                    end;
                error -> {error, <<"Cannot find compiled search-box module">>}
            end
    end.

describe_search_box() ->
    try {ok, campy_search_box:describe()}
    catch Class:Reason -> error_text({Class, Reason}) end.

write_generated(Source) ->
    Path = filename:join([os:getenv("CAMPY_ROOT"), "generated", "search_box.slint"]),
    case file:write_file(Path, Source) of
        ok -> {ok, nil};
        {error, Reason} -> error_text(Reason)
    end.

generated_path(Name) ->
    filename:join([os:getenv("CAMPY_ROOT"), "generated", Name]).

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.

