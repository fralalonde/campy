-module(campy_project_ffi).
-export([read_file/1, write_file/2, make_dir/1]).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            {ok, Binary};
        {error, Reason} ->
            {error, format("read ~ts: ~ts", [Path, file:format_error(Reason)])}
    end.

write_file(Path, Data) ->
    _ = filelib:ensure_dir(Path),
    case file:write_file(Path, Data) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, format("write ~ts: ~ts", [Path, file:format_error(Reason)])}
    end.

make_dir(Path) ->
    case filelib:ensure_dir(filename:join(Path, "x")) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, format("mkdir ~ts: ~ts", [Path, file:format_error(Reason)])}
    end.

format(Template, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Template, Arguments)).
