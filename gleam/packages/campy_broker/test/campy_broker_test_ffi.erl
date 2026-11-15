-module(campy_broker_test_ffi).
-export([temp_dir/1]).

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
