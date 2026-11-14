-module(campy_manifest_test_ffi).
-export([temp_dir/1, fixture_dir/1, copy_dir/2, append_bytes/2,
         write_version_2_manifest/1]).

%% A unique scratch directory under the system temp directory.
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

%% An absolute path to a checked-in fixture directory (test/fixtures/<Name>).
%% `gleam test` runs with the package directory as the working directory.
fixture_dir(Name) ->
    Path = filename:absname(
        filename:join(["test", "fixtures", unicode:characters_to_list(Name)])),
    unicode:characters_to_binary(Path).

%% Copies the regular files of From into To (created if needed).
copy_dir(From, To) ->
    Source = unicode:characters_to_list(From),
    Target = unicode:characters_to_list(To),
    case file:list_dir(Source) of
        {ok, Names} ->
            ok = filelib:ensure_dir(filename:join(Target, "placeholder")),
            lists:foreach(
                fun(Name) ->
                    case file:read_file(filename:join(Source, Name)) of
                        {ok, Data} ->
                            ok = file:write_file(filename:join(Target, Name), Data);
                        {error, Reason} ->
                            error_text(Reason)
                    end
                end,
                Names),
            {ok, nil};
        {error, Reason} ->
            error_text(Reason)
    end.

append_bytes(Path, Extra) ->
    Native = unicode:characters_to_list(Path),
    case file:read_file(Native) of
        {ok, Original} ->
            case file:write_file(Native, <<Original/binary, Extra/binary>>) of
                ok -> {ok, nil};
                {error, Reason} -> error_text(Reason)
            end;
        {error, Reason} ->
            error_text(Reason)
    end.

%% Writes a syntactically valid manifest file with an unsupported version tag.
write_version_2_manifest(Path) ->
    Native = unicode:characters_to_list(Path),
    Term = {manifest, 2, {manifest, <<"cat_cafe">>, <<"Cat Café">>, 1,
                          <<"campy_app_cat_cafe">>, [], <<"campy.campy">>,
                          <<"cat-cafe">>, 11, [], [],
                          {capabilities, 27, 1}, [], <<>>, none}},
    case filelib:ensure_dir(Native) of
        ok ->
            case file:write_file(Native, term_to_binary(Term, [compressed])) of
                ok -> {ok, nil};
                {error, Reason} -> error_text(Reason)
            end;
        {error, Reason} ->
            error_text(Reason)
    end.

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
