-module(campy_broker_ffi).
-include_lib("kernel/include/file.hrl").
-export([run_build/1, root/0, remove_tree/1, copy_file/2, list_versions/1,
         list_files/1, getenv/1, write_file/2, save_state/2, load_state/1,
         now_ms/0]).

%% Port-spawn `gleam build` in Dir, merging stderr into stdout. This is the
%% campy_hot_ffi pattern: the build runs in its own OS process so the host VM
%% survives compiler crashes, and the error text shapes are identical.
run_build(Dir) ->
    case os:find_executable("gleam") of
        false ->
            {error, <<"gleam executable not found">>};
        Exe ->
            Port = open_port({spawn_executable, Exe},
                             [{cd, unicode:characters_to_list(Dir)},
                              {args, ["build"]}, binary,
                              exit_status, stderr_to_stdout]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Code}} ->
            {error, <<"gleam build failed (", (integer_to_binary(Code))/binary,
                      "): ", Acc/binary>>}
    after 180000 ->
        catch port_close(Port),
        {error, <<"gleam build timed out">>}
    end.

%% Repository root: CAMPY_ROOT when the workspace runner exported it, otherwise
%% the nearest ancestor of the working directory holding campy.campy. This keeps
%% `gleam test` (package cwd) and the repo-root CLI on the same generated/ tree.
root() ->
    case os:getenv("CAMPY_ROOT") of
        false ->
            unicode:characters_to_binary(find_root(filename:absname(".")));
        Value ->
            unicode:characters_to_binary(Value)
    end.

find_root(Dir) ->
    case filelib:is_file(filename:join(Dir, "campy.campy")) of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> filename:absname(".");
                false -> find_root(Parent)
            end
    end.

%% Delete a file or a directory tree. A missing path is already clean.
remove_tree(Path) ->
    case remove_path(unicode:characters_to_list(Path)) of
        ok ->
            {ok, nil};
        {error, enoent} ->
            {ok, nil};
        {error, Reason} ->
            error_text("cannot remove ~ts: ~p", [Path, Reason])
    end.

%% Never descend through a dependency link. On Windows, directory symlinks
%% need del_dir rather than delete; OTP 27's del_dir_r leaves those behind.
remove_path(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            case file:delete(Path) of
                {error, eperm} -> file:del_dir(Path);
                {error, eacces} -> file:del_dir(Path);
                Result -> Result
            end;
        {ok, #file_info{type = directory}} ->
            case file:list_dir(Path) of
                {ok, Names} -> remove_children(Path, Names);
                Error -> Error
            end;
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.

remove_children(Path, []) -> file:del_dir(Path);
remove_children(Path, [Name | Rest]) ->
    case remove_path(filename:join(Path, Name)) of
        ok -> remove_children(Path, Rest);
        Error -> Error
    end.

%% Copy one artifact file, creating the destination directory as needed.
copy_file(Source, Destination) ->
    Target = unicode:characters_to_list(Destination),
    case filelib:ensure_dir(Target) of
        ok ->
            case file:copy(unicode:characters_to_list(Source), Target) of
                {ok, _Bytes} ->
                    {ok, nil};
                {error, Reason} ->
                    error_text("cannot copy ~ts to ~ts: ~p",
                               [Source, Destination, Reason])
            end;
        {error, Reason} ->
            error_text("cannot create directory for ~ts: ~p",
                       [Destination, Reason])
    end.

%% Numeric subdirectory names under an artifact root, e.g. [1, 2, 7]. Missing
%% directories and non-numeric entries are ignored.
list_versions(Directory) ->
    case file:list_dir(unicode:characters_to_list(Directory)) of
        {ok, Names} ->
            lists:sort([Version || Name <- Names,
                                   {ok, Version} <- [version_number(Name)]]);
        {error, _} ->
            []
    end.

version_number(Name) ->
    case string:to_integer(Name) of
        {Version, ""} when Version > 0 -> {ok, Version};
        _ -> error
    end.

%% Sorted relative paths of every regular file under a directory. Used by tests
%% to assert the exact artifact contents.
list_files(Directory) ->
    case filelib:is_dir(Directory) of
        false ->
            {error, error_text_text("not a directory: ~ts", [Directory])};
        true ->
            Base = filename:absname(unicode:characters_to_list(Directory)),
            Prefix = Base ++ "/",
            Files =
                filelib:fold_files(Base, ".*", true, fun(Path, Acc) ->
                    case lists:prefix(Prefix, Path) of
                        true -> [lists:nthtail(length(Prefix), Path) | Acc];
                        false -> Acc
                    end
                end,
                []),
            {ok, lists:sort([unicode:characters_to_binary(File) || File <- Files])}
    end.

%% Environment lookup used by the build-acceptance test's CAMPY_FAST_ONLY skip.
getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> none;
        Value -> {some, unicode:characters_to_binary(Value)}
    end.

%% Test helper: write a file, creating parent directories (probe artifact dirs).
write_file(Path, Contents) ->
    case filelib:ensure_dir(unicode:characters_to_list(Path)) of
        ok ->
            case file:write_file(unicode:characters_to_list(Path), Contents) of
                ok ->
                    {ok, nil};
                {error, Reason} ->
                    error_text("cannot write ~ts: ~p", [Path, Reason])
            end;
        {error, Reason} ->
            error_text("cannot create directory for ~ts: ~p", [Path, Reason])
    end.

%% Broker state is a versioned compressed Erlang term, following the
%% campy_manifest codec: an outer format tag, validation on load, and explicit
%% errors on mismatch. Local phase-1 state is advisory, so Gleam callers treat
%% any load error as an empty state.
save_state(Path, State) ->
    Native = unicode:characters_to_list(Path),
    case filelib:ensure_dir(Native) of
        ok ->
            Term = {broker_state, 1, State},
            case file:write_file(Native, term_to_binary(Term, [compressed])) of
                ok ->
                    {ok, nil};
                {error, Reason} ->
                    error_text("cannot write ~ts: ~p", [Path, Reason])
            end;
        {error, Reason} ->
            error_text("cannot create directory for ~ts: ~p", [Path, Reason])
    end.

load_state(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                {broker_state, 1, State} ->
                    case valid_state(State) of
                        true -> {ok, State};
                        false -> {error, <<"Invalid broker state file">>}
                    end;
                {broker_state, Version, _} when is_integer(Version) ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("unsupported broker state version: ~p",
                                      [Version]))};
                _ ->
                    {error, <<"Unsupported broker state format">>}
            catch
                _:_ -> {error, <<"Invalid broker state file">>}
            end;
        {error, enoent} ->
            {error, <<"Broker state file not found">>};
        {error, Reason} ->
            error_text("cannot read ~ts: ~p", [Path, Reason])
    end.

valid_state({broker_state, Current, Deployments})
  when is_list(Current), is_list(Deployments) ->
    lists:all(fun valid_current/1, Current) andalso
        lists:all(fun valid_deployment/1, Deployments);
valid_state(_) ->
    false.

valid_current({App, Version}) ->
    is_binary(App) andalso is_integer(Version);
valid_current(_) ->
    false.

valid_deployment({deployment, App, Version, Runner, Status, Detail, AtMs}) ->
    is_binary(App) andalso is_integer(Version) andalso is_binary(Runner)
        andalso is_binary(Status) andalso is_binary(Detail)
        andalso is_integer(AtMs);
valid_deployment(_) ->
    false.

%% Wall-clock milliseconds for deployment records.
now_ms() ->
    erlang:system_time(millisecond).

error_text(Format, Arguments) ->
    {error, error_text_text(Format, Arguments)}.

error_text_text(Format, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Format, Arguments)).
