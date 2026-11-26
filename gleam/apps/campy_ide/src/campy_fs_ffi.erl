-module(campy_fs_ffi).
-export([list_dir/1, home/0, root/0, abs_path/1, make_dir/1, read_file/1,
         write_file/2]).

%% Filesystem browsing for the in-app file dialog. Entries come back as
%% {Name, IsDir} pairs (binaries); the caller sorts and renders them.

home() ->
    Dir =
        case os:type() of
            {win32, _} -> os:getenv("USERPROFILE", "C:\\");
            _ -> os:getenv("HOME", "/")
        end,
    unicode:characters_to_binary(Dir).

%% Project paths are stored relative to CAMPY_ROOT (the same rule the project
%% codec uses), so the browser needs the absolute form to start somewhere.
root() ->
    unicode:characters_to_binary(
      case os:getenv("CAMPY_ROOT") of
          false -> ".";
          Value -> Value
      end).

abs_path(Path) ->
    List = unicode:characters_to_list(Path),
    Absolute = case filename:pathtype(List) of
        absolute -> List;
        _ -> filename:join(unicode:characters_to_list(root()), List)
    end,
    unicode:characters_to_binary(Absolute).

list_dir(Path) ->
    case file:list_dir(unicode:characters_to_list(Path)) of
        {ok, Names} ->
            {ok,
                [{unicode:characters_to_binary(N),
                  filelib:is_dir(filename:join(unicode:characters_to_list(Path), N))}
                 || N <- Names]};
        {error, _} -> {error, nil}
    end.

make_dir(Path) ->
    case filelib:ensure_dir(unicode:characters_to_list(Path) ++ "/.") of
        ok -> {ok, nil};
        {error, Reason} -> error_text(Reason)
    end.

%% External module sources: the IDE reads the file on open and writes it back
%% on edit; the project codec itself only stores the path.
read_file(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Bytes} ->
            case unicode:characters_to_binary(Bytes) of
                Bin when is_binary(Bin) -> {ok, Bin};
                _ -> error_text(invalid_encoding)
            end;
        {error, Reason} -> error_text(Reason)
    end.

write_file(Path, Text) ->
    case file:write_file(unicode:characters_to_list(Path),
                         unicode:characters_to_binary(Text)) of
        ok -> {ok, nil};
        {error, Reason} -> error_text(Reason)
    end.

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
