-module(campy_app_ffi).
-export([apply_handler/2, terminate_supervisor/1, has_display/0]).

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
                    false ->
                        {error, <<"no handler">>}
                end;
            _ ->
                {error, <<"no handler">>}
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
