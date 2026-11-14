-module(campy_appgen_ffi).
-export([ascii_fold/1, write_file/2, read_file/1, list_files/1]).

%% Unicode-aware fold used by `slug`: compatibility-decompose the text and drop
%% combining marks so accented letters lose their accent ("é" -> "e"). The
%% caller then keeps only [a-z0-9_] and turns everything else into a separator.
ascii_fold(Text) ->
    unicode:characters_to_binary(
        strip_marks(unicode:characters_to_nfkd_list(Text))).

strip_marks(Characters) when is_list(Characters) ->
    [Character || Character <- Characters, not is_combining(Character)];
strip_marks(Binary) when is_binary(Binary) ->
    strip_marks(unicode:characters_to_list(Binary)).

is_combining(Character) ->
    (Character >= 16#0300 andalso Character =< 16#036F)
    orelse (Character >= 16#1AB0 andalso Character =< 16#1AFF)
    orelse (Character >= 16#1DC0 andalso Character =< 16#1DFF)
    orelse (Character >= 16#20D0 andalso Character =< 16#20FF)
    orelse (Character >= 16#FE20 andalso Character =< 16#FE2F).

%% Write one generated file, creating parent directories as needed.
write_file(Path, Contents) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Contents) of
                ok ->
                    {ok, nil};
                {error, Reason} ->
                    {error, error_text("cannot write ~ts: ~p", [Path, Reason])}
            end;
        {error, Reason} ->
            {error,
             error_text("cannot create directory for ~ts: ~p", [Path, Reason])}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            {ok, Binary};
        {error, Reason} ->
            {error, error_text("cannot read ~ts: ~p", [Path, Reason])}
    end.

%% Sorted relative paths of every regular file under a directory. Used by the
%% tests to compare a generated tree against its golden copy.
list_files(Directory) ->
    case filelib:is_dir(Directory) of
        false ->
            {error, error_text("not a directory: ~ts", [Directory])};
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

error_text(Format, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Format, Arguments)).
