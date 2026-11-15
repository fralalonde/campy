-module(campy_runner_ffi).
-export([add_path/1, validate_modules/2, load_modules/2, claim_app/2,
         release_app/2, resolve_path/2, has_display/0, getenv/1]).

%% Module loading follows the campy_hot_ffi discipline: soft-purge the old
%% version, load the new beam, and retry once through a hard purge when the
%% old version is still referenced. The runner pauses event delivery around a
%% swap, so no new handler dispatch starts while modules move.

add_path(EBin) ->
    Path = unicode:characters_to_list(EBin),
    case code:add_patha(Path) of
        true -> {ok, nil};
        {error, Reason} ->
            error_text("cannot add code path ~ts: ~p", [EBin, Reason])
    end.

%% Validate every beam before the update purges or loads anything. A corrupt
%% or missing beam must fail the update while the old artifact is still live.
validate_modules(EBin, Modules) ->
    Base = unicode:characters_to_list(EBin),
    validate_modules_loop(Modules, Base).

validate_modules_loop([], _Base) ->
    {ok, nil};
validate_modules_loop([Module | Rest], Base) ->
    Name = unicode:characters_to_list(Module),
    File = filename:join(Base, Name ++ ".beam"),
    case beam_lib:chunks(File, [exports]) of
        {ok, {ActualModule, _Chunks}} ->
            case atom_to_binary(ActualModule, utf8) =:= Module of
                true -> validate_modules_loop(Rest, Base);
                false ->
                    error_text("beam ~ts declares module ~ts", [File, ActualModule])
            end;
        {error, beam_lib, Reason} ->
            error_text("cannot load module ~ts: ~p", [Module, Reason]);
        {error, Reason} ->
            error_text("cannot read module ~ts: ~p", [Module, Reason])
    end.

load_modules(_EBin, []) ->
    {ok, nil};
load_modules(EBin, [Module | Rest]) ->
    case load_one(Module) of
        ok -> load_modules(EBin, Rest);
        {error, _} = Error -> Error
    end.

load_one(ModuleBin) ->
    Module = binary_to_atom(ModuleBin, utf8),
    _ = code:soft_purge(Module),
    case code:load_file(Module) of
        {module, Module} ->
            ok;
        {error, not_purged} ->
            _ = code:purge(Module),
            case code:load_file(Module) of
                {module, Module} -> ok;
                {error, Reason} ->
                    load_error(ModuleBin, Reason)
            end;
        {error, Reason} ->
            load_error(ModuleBin, Reason)
    end.

load_error(Module, Reason) ->
    error_text("cannot load module ~ts: ~p", [Module, Reason]).

%% One runner per app slug in a VM. The registry lives in a public ETS table
%% owned by a small permanent process so it outlives any one runner actor.
claim_app(App, Pid) ->
    ensure_registry(),
    case ets:lookup(campy_runner_registry, App) of
        [] ->
            ets:insert(campy_runner_registry, {App, Pid}),
            true;
        [{App, Existing}] ->
            case Existing =:= Pid orelse not is_process_alive(Existing) of
                true ->
                    ets:insert(campy_runner_registry, {App, Pid}),
                    true;
                false ->
                    false
            end
    end.

release_app(App, Pid) ->
    ensure_registry(),
    _ = ets:match_delete(campy_runner_registry, {App, Pid}),
    nil.

ensure_registry() ->
    case ets:whereis(campy_runner_registry) of
        undefined ->
            Parent = self(),
            _ = spawn(fun() -> registry_owner(Parent) end),
            receive
                campy_runner_registry_ready -> ok
            after 5000 -> ok
            end;
        _ ->
            ok
    end.

registry_owner(Parent) ->
    case ets:whereis(campy_runner_registry) of
        undefined ->
            try
                _ = ets:new(campy_runner_registry,
                            [named_table, public, set,
                             {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end,
    Parent ! campy_runner_registry_ready,
    registry_loop().

registry_loop() ->
    receive
        _ -> registry_loop()
    end.

%% Manifest project paths are absolute for tests and may be repo-relative for
%% real builds; resolve the latter against the broker root, which follows
%% CAMPY_ROOT or walks up to campy.campy.
resolve_path(Path, Root) ->
    PathList = unicode:characters_to_list(Path),
    case filename:pathtype(PathList) of
        absolute ->
            Path;
        _ ->
            RootList = unicode:characters_to_list(Root),
            unicode:characters_to_binary(filename:join(RootList, PathList))
    end.

%% Test/session gating: a real bridge session needs a display server.
has_display() ->
    env_set("DISPLAY") orelse env_set("WAYLAND_DISPLAY").

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> none;
        Value -> {some, unicode:characters_to_binary(Value)}
    end.

env_set(Name) ->
    case os:getenv(Name) of
        false -> false;
        "" -> false;
        _ -> true
    end.

error_text(Format, Arguments) ->
    {error, unicode:characters_to_binary(io_lib:format(Format, Arguments))}.
