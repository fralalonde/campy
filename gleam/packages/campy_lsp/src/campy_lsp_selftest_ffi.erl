-module(campy_lsp_selftest_ffi).
-export([workspace_dir/0, write_workspace/0, write_source/2, fail/1, dump/0, msg_kind/1, msg_rows/1,
         msg_labels/1, msg_items/1, msg_pos/1, wait/1]).

workspace_dir() ->
    unicode:characters_to_binary(
        filename:absname("generated/lsp-selftest")).

write_workspace() ->
    Dir = workspace_dir(),
    filelib:ensure_path(binary_to_list(<<Dir/binary, "/src">>)),
    GleamToml =
        <<"name = \"lsp_workspace\"\nversion = \"0.1.0\"\ntarget = \"erlang\"\n">>,
    file:write_file(binary_to_list(<<Dir/binary, "/gleam.toml">>), GleamToml),
    os:cmd("cd " ++ binary_to_list(Dir) ++ " && gleam deps download"),
    ok.

write_source(Name, Text) ->
    Dir = workspace_dir(),
    file:write_file(
        binary_to_list(<<Dir/binary, "/src/", Name/binary, ".gleam">>),
        Text),
    ok.

fail(Message) ->
    erlang:error(unicode:characters_to_list(Message)).

%% Drain and pretty-print the master mailbox (selftest debugging).
dump() ->
    receive
        M ->
            io:format("MAILBOX ~p~n", [M]),
            dump()
    after 200 ->
        ok
    end.

msg_kind(Msg) when is_tuple(Msg), tuple_size(Msg) >= 1 ->
    Kind = element(1, Msg),
    case Kind of
        A when is_atom(A) -> atom_to_binary(A, utf8);
        B when is_binary(B) -> B
    end;
msg_kind(_) ->
    <<"unknown">>.

msg_rows({lsp_diagnostics, _File, Rows}) -> Rows;
msg_rows(_) -> [].

msg_labels({lsp_completions, _File, Labels}) -> Labels;
msg_labels(_) -> [].

msg_items({lsp_symbols, _File, Items}) -> Items;
msg_items(_) -> [].

msg_pos({lsp_definition, _File, Line, Char}) -> {Line, Char};
msg_pos(_) -> {0, 0}.

wait(Ms) ->
    receive
        Msg = {lsp_diagnostics, _, _} -> {ok, Msg};
        Msg = {lsp_completions, _, _} -> {ok, Msg};
        Msg = {lsp_symbols, _, _} -> {ok, Msg};
        Msg = {lsp_definition, _, _, _} -> {ok, Msg};
        Msg = {lsp_no_definition} -> {ok, Msg};
        Msg = {lsp_edits, _, _} -> {ok, Msg};
        {lsp_down, _} = Msg -> {ok, Msg}
    after Ms ->
        {error, nil}
    end.
