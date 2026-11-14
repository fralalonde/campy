-module(campy_manifest_ffi).
-export([save_manifest/2, load_manifest/1, digest_dir/1]).

%% Manifests are stored as versioned compressed Erlang terms. Paths are
%% relative to CAMPY_ROOT (set by scripts/workspace.py) unless absolute.
save_manifest(Path, Manifest) ->
    Full = resolve(Path),
    case filelib:ensure_dir(Full) of
        ok ->
            Term = {manifest, 1, Manifest},
            case file:write_file(Full, term_to_binary(Term, [compressed])) of
                ok -> {ok, nil};
                {error, Reason} -> error_text(Reason)
            end;
        {error, Reason} ->
            error_text(Reason)
    end.

load_manifest(Path) ->
    Full = resolve(Path),
    case file:read_file(Full) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                {manifest, 1, Manifest} ->
                    case validate(Manifest) of
                        ok -> {ok, Manifest};
                        error -> {error, <<"Invalid manifest file">>}
                    end;
                {manifest, Version, _} when is_integer(Version) ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("unsupported manifest version: ~p", [Version]))};
                _ ->
                    {error, <<"Unsupported manifest format">>}
            catch
                _:_ -> {error, <<"Invalid manifest file">>}
            end;
        {error, enoent} ->
            {error, <<"Manifest file not found">>};
        {error, Reason} ->
            error_text(Reason)
    end.

%% sha256 over the concatenation of (relative path, size, sha256) for every
%% *.beam file in the directory, in sorted-path order.
digest_dir(Directory) ->
    Full = resolve(Directory),
    Files = lists:sort(filelib:wildcard(filename:join(Full, "*.beam"))),
    case digest_files(Files, []) of
        {ok, Entries} ->
            hex(crypto:hash(sha256, Entries));
        error ->
            <<>>
    end.

digest_files([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
digest_files([File | Rest], Acc) ->
    case file:read_file(File) of
        {ok, Data} ->
            Name = unicode:characters_to_binary(filename:basename(File)),
            Entry = [Name, 0, integer_to_binary(byte_size(Data)), 0,
                     hex(crypto:hash(sha256, Data)), $\n],
            digest_files(Rest, [Entry | Acc]);
        {error, _} ->
            error
    end.

hex(Binary) ->
    << <<(hex_digit(Nibble))>> || <<Nibble:4>> <= Binary >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

validate({manifest, App, Title, Version, Entry, Modules, ProjectPath, ModuleId,
          Schema, Migration, Natives, Capabilities, Assets, ContentDigest,
          Signature})
  when is_binary(App), is_binary(Title), is_integer(Version),
       is_binary(Entry), is_binary(ProjectPath), is_binary(ModuleId),
       is_integer(Schema), is_binary(ContentDigest) ->
    case lists:all(fun is_binary/1, Modules)
         andalso lists:all(fun valid_native/1, Natives)
         andalso lists:all(fun valid_step/1, Migration)
         andalso lists:all(fun is_binary/1, Assets)
         andalso valid_capabilities(Capabilities)
         andalso valid_signature(Signature) of
        true -> ok;
        false -> error
    end;
validate(_) ->
    error.

valid_native({native, Target, Digest, FilePath}) ->
    is_binary(Target) andalso is_binary(Digest) andalso is_binary(FilePath);
valid_native(_) ->
    false.

valid_step({step, From, To, Note}) ->
    is_integer(From) andalso is_integer(To) andalso is_binary(Note);
valid_step(_) ->
    false.

valid_capabilities({capabilities, OtpMin, BridgeProtocol}) ->
    is_integer(OtpMin) andalso is_integer(BridgeProtocol);
valid_capabilities(_) ->
    false.

valid_signature(none) ->
    true;
valid_signature({some, Signature}) ->
    is_binary(Signature);
valid_signature(_) ->
    false.

resolve(Path) ->
    Native = unicode:characters_to_list(Path),
    case filename:pathtype(Native) of
        absolute -> Native;
        _ ->
            Root = case os:getenv("CAMPY_ROOT") of
                false -> ".";
                Value -> Value
            end,
            filename:join([Root, Native])
    end.

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
