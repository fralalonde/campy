-module(campy_form_fixture_ffi).
-export([read_file/1, write_file/2, update_fixture/0]).

%% Golden-fixture plumbing for `live_preview_test`. Paths are relative to the
%% package directory (the `gleam test` working directory).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, unicode:characters_to_binary(Binary)};
        {error, Reason} -> {error, error_text(Reason)}
    end.

write_file(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, unicode:characters_to_binary(Contents)),
    nil.

%% `CAMPY_UPDATE_FIXTURE=1 gleam test` rewrites the checked-in golden instead
%% of comparing against it.
update_fixture() ->
    case os:getenv("CAMPY_UPDATE_FIXTURE") of
        "1" -> true;
        _ -> false
    end.

error_text(Reason) ->
    unicode:characters_to_binary(file:format_error(Reason)).
