-module(campy_broker_test_ffi).
-export([temp_dir/1, remove_tree_keeps_link_target/1]).

remove_tree_keeps_link_target(Base) ->
    Root = unicode:characters_to_list(Base),
    Tree = filename:join(Root, "tree"),
    Target = filename:join(Root, "target"),
    Kept = filename:join(Target, "keep.txt"),
    ok = filelib:ensure_dir(Kept),
    ok = file:write_file(Kept, <<"keep">>),
    ok = filelib:ensure_dir(filename:join(Tree, "placeholder")),
    try
        case file:make_symlink(Target, filename:join(Tree, "linked")) of
            ok -> ok;
            {error, eperm} ->
                %% OTP's Windows symlink creation requires elevation even
                %% when Gleam can create links using Developer Mode.
                io:format("Symlink fixture unavailable (eperm); checking ordinary cleanup~n")
        end,
        {ok, nil} = campy_broker_ffi:remove_tree(unicode:characters_to_binary(Tree)),
        {error, enoent} = file:read_link_info(Tree),
        {ok, <<"keep">>} = file:read_file(Kept),
        %% The public helper also promises to remove individual files.
        {ok, nil} = campy_broker_ffi:remove_tree(unicode:characters_to_binary(Kept)),
        {ok, nil} = campy_broker_ffi:remove_tree(unicode:characters_to_binary(Kept)),
        nil
    after
        campy_broker_ffi:remove_tree(Base)
    end.

%% A unique scratch directory under the system temp directory, so state-store
%% tests never touch the repository's advisory `generated/broker/state.campy`.
temp_dir(Prefix) ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end,
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Name = unicode:characters_to_list(Prefix) ++ "-" ++ Unique,
    Path = filename:join(Base, Name),
    ok = filelib:ensure_dir(filename:join(Path, "placeholder")),
    unicode:characters_to_binary(Path).
