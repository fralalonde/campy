-module(campy_manifest_ffi).
-export([save_manifest/2, load_manifest/1, digest_dir/1, sha256/1]).

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
            hex(sha256(Entries));
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
                     hex(sha256(Data)), $\n],
            digest_files(Rest, [Entry | Acc]);
        {error, _} ->
            error
    end.

%% The OTP crypto NIF is unavailable on some hosts (an OpenSSL without the
%% SM4 symbols OTP 28 links against); a pure-Erlang sha256 keeps manifests
%% and their digests stable everywhere, with identical output.
sha256(Data) ->
    try
        crypto:hash(sha256, Data)
    catch _:_ ->
        sha256_pure(iolist_to_binary(Data))
    end.

-define(SHA_M, 16#ffffffff).

sha256_pure(Data) ->
    K = [16#428a2f98, 16#71374491, 16#b5c0fbcf, 16#e9b5dba5,
         16#3956c25b, 16#59f111f1, 16#923f82a4, 16#ab1c5ed5,
         16#d807aa98, 16#12835b01, 16#243185be, 16#550c7dc3,
         16#72be5d74, 16#80deb1fe, 16#9bdc06a7, 16#c19bf174,
         16#e49b69c1, 16#efbe4786, 16#0fc19dc6, 16#240ca1cc,
         16#2de92c6f, 16#4a7484aa, 16#5cb0a9dc, 16#76f988da,
         16#983e5152, 16#a831c66d, 16#b00327c8, 16#bf597fc7,
         16#c6e00bf3, 16#d5a79147, 16#06ca6351, 16#14292967,
         16#27b70a85, 16#2e1b2138, 16#4d2c6dfc, 16#53380d13,
         16#650a7354, 16#766a0abb, 16#81c2c92e, 16#92722c85,
         16#a2bfe8a1, 16#a81a664b, 16#c24b8b70, 16#c76c51a3,
         16#d192e819, 16#d6990624, 16#f40e3585, 16#106aa070,
         16#19a4c116, 16#1e376c08, 16#2748774c, 16#34b0bcb5,
         16#391c0cb3, 16#4ed8aa4a, 16#5b9cca4f, 16#682e6ff3,
         16#748f82ee, 16#78a5636f, 16#84c87814, 16#8cc70208,
         16#90befffa, 16#a4506ceb, 16#bef9a3f7, 16#c67178f2],
    H0 = [16#6a09e667, 16#bb67ae85, 16#3c6ef372, 16#a54ff53a,
          16#510e527f, 16#9b05688c, 16#1f83d9ab, 16#5be0cd19],
    H = lists:foldl(fun(Block, Acc) -> sha_block(Block, K, Acc) end,
                    H0, sha_blocks(sha_pad(Data))),
    << <<X:32/big>> || X <- H >>.

sha_pad(Data) ->
    Bits = byte_size(Data) * 8,
    Zeroes = (55 - byte_size(Data)) band 63,
    <<Data/binary, 16#80, 0:Zeroes/unit:8, Bits:64/big>>.

sha_blocks(<<Block:64/binary, Rest/binary>>) ->
    [Block | sha_blocks(Rest)];
sha_blocks(<<>>) ->
    [].

sha_block(Block, K, [A0, B0, C0, D0, E0, F0, G0, H0]) ->
    W0 = [X || <<X:32/big>> <= Block],
    W = lists:foldl(
          fun(I, Acc) ->
                  S0 = sha_rotr(lists:nth(I - 14, Acc), 7)
                       bxor sha_rotr(lists:nth(I - 14, Acc), 18)
                       bxor (lists:nth(I - 14, Acc) bsr 3),
                  S1 = sha_rotr(lists:nth(I - 1, Acc), 17)
                       bxor sha_rotr(lists:nth(I - 1, Acc), 19)
                       bxor (lists:nth(I - 1, Acc) bsr 10),
                  Wi = (S1 + lists:nth(I - 6, Acc) + S0
                        + lists:nth(I - 15, Acc)) band ?SHA_M,
                  Acc ++ [Wi]
          end, W0, lists:seq(16, 63)),
    {A, B, C, D, E, F, G, H} =
        lists:foldl(
          fun(I, {A, B, C, D, E, F, G, H}) ->
                  S1 = sha_rotr(E, 6) bxor sha_rotr(E, 11) bxor sha_rotr(E, 25),
                  Ch = (E band F) bxor (bnot E band G),
                  T1 = (H + S1 + Ch + lists:nth(I + 1, K)
                        + lists:nth(I + 1, W)) band ?SHA_M,
                  S0 = sha_rotr(A, 2) bxor sha_rotr(A, 13) bxor sha_rotr(A, 22),
                  Maj = (A band B) bxor (A band C) bxor (B band C),
                  T2 = (S0 + Maj) band ?SHA_M,
                  {(T1 + T2) band ?SHA_M, A, B, C,
                   (D + T1) band ?SHA_M, E, F, G}
          end,
          {A0, B0, C0, D0, E0, F0, G0, H0},
          lists:seq(0, 63)),
    [(A0 + A) band ?SHA_M, (B0 + B) band ?SHA_M, (C0 + C) band ?SHA_M,
     (D0 + D) band ?SHA_M, (E0 + E) band ?SHA_M, (F0 + F) band ?SHA_M,
     (G0 + G) band ?SHA_M, (H0 + H) band ?SHA_M].

sha_rotr(X, N) ->
    (X bsr N) bor ((X band ((1 bsl N) - 1)) bsl (32 - N)).

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
