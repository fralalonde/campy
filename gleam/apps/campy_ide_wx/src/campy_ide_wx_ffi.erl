-module(campy_ide_wx_ffi).
-export([make_dir/1, write_file/2, compile_and_load/2, cwd/0, start_app_on/3, load_code_on/3, pause_on/2, resume_on/2]).

make_dir(Dir) ->
    case filelib:ensure_path(Dir) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

write_file(Path, Text) ->
    case file:write_file(Path, Text) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Build the scratch package at Dir with the Gleam CLI, add its ebin to the
%% code path, and ensure Module is loaded. Ok on success; an error message
%% with the compiler output on failure.
compile_and_load(Dir, Module) ->
    Cmd = unicode:characters_to_list(
        unicode:characters_to_binary(
            ["cd \"", Dir, "\" && gleam build 2>&1"]
        )
    ),
    Out = os:cmd(Cmd),
    Ebin = unicode:characters_to_list(
        filename:join([Dir, "build", "dev", "erlang", "campy_apps", "ebin"])
    ),
    case code:add_patha(Ebin) of
        {error, Reason} ->
            {error, reason(Reason)};
        _ ->
            Atom = binary_to_atom(Module, utf8),
            case code:ensure_loaded(Atom) of
                {module, _} -> {ok, nil};
                {error, Reason2} ->
                    {error, unicode:characters_to_binary(
                              io_lib:format("~p: ~s", [Reason2, Out]))}
            end
    end.

%% Start the app actor on a peer node through the installed runner. The Spec
%% and the reply subject are plain terms and cross erpc; the transport wraps
%% the runner's Result, so strip its {ok, _} layer.
start_app_on(Node, Spec, Reply) ->
    %% The runner's start_app returns {ok, Subject} | {error, Reason}; rpc
    %% delivers it as-is (unlike campy_peer:call, which wraps once more).
    case rpc:call(node_name(Node), campy_runner, start_app, [Spec, Reply], 15000) of
        {ok, Subject} -> {ok, Subject};
        {error, Reason} -> {error, reason(Reason)};
        {badrpc, Reason} -> {error, reason(Reason)};
        Other -> {error, format("~p", [Other])}
    end.

%% Load new code on a peer via the installed campy_app.load_code.
load_code_on(Node, Module, BeamPath) ->
    case rpc:call(node_name(Node), campy_app, load_code,
                  [Module, BeamPath], 15000) of
        {badrpc, Reason} -> {error, reason(Reason)};
        Result -> Result
    end.

pause_on(Node, Pid) ->
    case rpc:call(node_name(Node), sys, suspend, [Pid], 15000) of
        {badrpc, Reason} -> {error, reason(Reason)};
        _ -> {ok, nil}
    end.

resume_on(Node, Pid) ->
    case rpc:call(node_name(Node), sys, resume, [Pid], 15000) of
        {badrpc, Reason} -> {error, reason(Reason)};
        _ -> {ok, nil}
    end.

node_name(Node) when is_binary(Node) -> binary_to_atom(Node, utf8);
node_name(Node) when is_atom(Node) -> Node.

format(Template, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Template, Arguments)).

%% Absolute process working directory; the IDE runs from its package dir
%% (gleam/apps/campy_ide_wx), three levels under the repo root.
cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
