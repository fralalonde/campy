-module(campy_project_test_ffi).
-export([temp_dir/0, remove_dir/1, read_file/1, write_file/2]).

temp_dir() ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp/opencode";
            Value -> Value
        end,
    Dir = filename:join(
        Base,
        "campy-project-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    unicode:characters_to_binary(Dir).

remove_dir(Dir) ->
    _ = file:del_dir_r(Dir),
    nil.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, Binary};
        {error, Reason} -> {error, file:format_error(Reason)}
    end.

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, file:format_error(Reason)}
    end.
