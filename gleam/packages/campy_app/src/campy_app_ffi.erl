-module(campy_app_ffi).
-export([apply_handler/2, terminate_supervisor/1, has_display/0, post_form/2]).

%% Handler ABI v1: zero-argument functions, nil return. The module is loaded
%% first because erlang:function_exported/3 answers false for unloaded modules;
%% generated apps only reference their handlers module dynamically.
apply_handler(ModBin, FunBin) ->
    try
        Mod = binary_to_atom(ModBin, utf8),
        Fun = binary_to_atom(FunBin, utf8),
        case code:ensure_loaded(Mod) of
            {module, Mod} ->
                case erlang:function_exported(Mod, Fun, 0) of
                    true ->
                        try Mod:Fun() of
                            nil -> {ok, nil};
                            Other ->
                                {error, unicode:characters_to_binary(
                                    io_lib:format("unexpected return: ~p", [Other]))}
                        catch
                            Class:Reason ->
                                {error, unicode:characters_to_binary(
                                    io_lib:format("~p:~p", [Class, Reason]))}
                        end;
                    %% An event nobody bound is an event nothing happens on:
                    %% it is not an error, and the app keeps running.
                    false ->
                        {ok, nil}
                end;
            %% The module is loaded but has no such function (the same
            %% unbound case), or it failed to load at all.
            _ ->
                {ok, nil}
        end
    catch
        Class0:Reason0 ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p:~p", [Class0, Reason0]))}
    end.

%% Stop a supervisor started by campy_otp's static_supervisor. sys:terminate
%% sends an OTP system message, so the supervisor shuts its children down
%% without requiring an exit signal aimed at a linked parent.
terminate_supervisor(Pid) ->
    _ = sys:terminate(Pid, shutdown, 5000),
    nil.

%% Test/session gating: a real bridge session needs a display server. This is
%% the env check the brief asks for; gleam_erlang 1.3.0 does not expose an
%% environment function, so it lives in this package's FFI.
has_display() ->
    env_set("DISPLAY") orelse env_set("WAYLAND_DISPLAY").

env_set(Name) ->
    case os:getenv(Name) of
        false -> false;
        "" -> false;
        _ -> true
    end.

%% A handler's one network primitive: POST a form body and give back the
%% response body. inets and ssl ship with OTP, so a generated app can reach a
%% token endpoint without an HTTP package. Non-2xx answers are errors, with the
%% status for the handler to log.
post_form(Url, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {binary_to_list(Url), [], "application/x-www-form-urlencoded", Body},
    HttpOptions = [{timeout, 15000}, {connect_timeout, 5000}],
    Options = [{body_format, binary}],
    case httpc:request(post, Request, HttpOptions, Options) of
        {ok, {{_, Status, _}, _, Response}} when Status >= 200, Status < 300 ->
            {ok, Response};
        {ok, {{_, Status, Reason}, _, Response}} ->
            {error, unicode:characters_to_binary(
                io_lib:format("HTTP ~p ~s: ~s", [Status, Reason, Response]))};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.
