-module(campy_ide_dialog_ffi).
-export([open_dialog/2]).

%% Native file dialogs on Linux. Zenity or KDialog are used when available and a
%% display is present; otherwise the caller falls back to the in-window dialog.
%% Mode is <<"open">>, <<"save">>, or <<"picture">>.

open_dialog(Mode, Initial0) ->
    case enabled() of
        false ->
            {error, <<"native dialogs unavailable">>};
        true ->
            Initial = resolve(Mode, to_list(Initial0)),
            Base = base_dir(Mode),
            case os:find_executable("zenity") of
                false ->
                    run_kdialog(Mode, Initial, Base);
                Exe ->
                    run(Mode, Exe, zenity_args(Mode, Initial), Base)
            end
    end.

enabled() ->
    os:getenv("CAMPY_NATIVE_DIALOGS") =/= "0"
        andalso (os:getenv("DISPLAY") =/= false
                 orelse os:getenv("WAYLAND_DISPLAY") =/= false).

resolve(<<"picture">>, Path) ->
    Path;
resolve(_, Path) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ -> filename:join(project_root(), Path)
    end.

base_dir(<<"picture">>) ->
    cwd();
base_dir(_) ->
    project_root().

project_root() ->
    case os:getenv("CAMPY_ROOT") of
        false -> cwd();
        Root -> Root
    end.

cwd() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.

zenity_args(<<"open">>, Initial) ->
    ["--file-selection",
     "--title=Open project",
     "--filename=" ++ start_path(<<"open">>, Initial),
     "--file-filter=Campy project | *.campy"];
zenity_args(<<"save">>, Initial) ->
    ["--file-selection",
     "--save",
     "--confirm-overwrite",
     "--title=Save project as",
     "--filename=" ++ start_path(<<"save">>, Initial),
     "--file-filter=Campy project | *.campy"];
zenity_args(<<"picture">>, Initial) ->
    ["--file-selection",
     "--title=Choose picture",
     "--filename=" ++ start_path(<<"picture">>, Initial),
     "--file-filter=Images | *.png *.jpg *.jpeg *.gif *.webp *.svg"].

run_kdialog(Mode, Initial, Base) ->
    case os:find_executable("kdialog") of
        false ->
            {error, <<"no native dialog available">>};
        Exe ->
            run(Mode, Exe, kdialog_args(Mode, Initial), Base)
    end.

kdialog_args(<<"open">>, Initial) ->
    ["--getopenfilename", start_path(<<"open">>, Initial),
     "*.campy|Campy project"];
kdialog_args(<<"save">>, Initial) ->
    ["--getsavefilename", start_path(<<"save">>, Initial),
     "*.campy|Campy project"];
kdialog_args(<<"picture">>, Initial) ->
    ["--getopenfilename", start_path(<<"picture">>, Initial),
     "*.png *.jpg *.jpeg *.gif *.webp *.svg|Images"].

start_path(<<"save">>, Path) ->
    case Path of
        "" -> ".";
        _ -> Path
    end;
start_path(_, "") ->
    ".";
start_path(_, Path) ->
    case filelib:is_dir(Path) of
        true -> filename:join(Path, "");
        false ->
            case filelib:is_regular(Path) of
                true -> Path;
                false -> filename:dirname(Path)
            end
    end.

run(Mode, Exe, Args, Base) ->
    Port = open_port({spawn_executable, Exe},
                     [{args, Args}, binary, exit_status, stderr_to_stdout]),
    collect(Port, Base, <<>>).

collect(Port, Base, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, Base, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            case string:trim(binary_to_list(Acc)) of
                "" ->
                    {ok, none};
                Path ->
                    {ok, {some, unicode:characters_to_binary(relativize(Path, Base))}}
            end;
        {Port, {exit_status, _}} ->
            {ok, none}
    after 300000 ->
        catch port_close(Port),
        {error, <<"dialog timed out">>}
    end.

relativize(Path, Base) ->
    AbsBase = filename:absname(Base),
    Prefix = string:trim(AbsBase, trailing, "/") ++ "/",
    case lists:prefix(Prefix, Path) of
        true -> lists:nthtail(length(Prefix), Path);
        false -> Path
    end.

to_list(Binary) when is_binary(Binary) ->
    unicode:characters_to_list(Binary);
to_list(List) when is_list(List) ->
    List.
