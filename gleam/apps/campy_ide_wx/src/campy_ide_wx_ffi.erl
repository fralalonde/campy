-module(campy_ide_wx_ffi).
-export([make_dir/1, write_file/2, read_text/1, settings_path/0, probe_message/1, inject_check/1, inject_step/1, probe_step_decode/1, compile_and_load/2, cwd/0, start_app_on/3, load_code_on/3, pause_on/2, resume_on/2, format_term/1, spawn_tracer/3, trace_send_receive/4, stop_tracer/2, processes_on/1, trace_log_text/1, copy_file/2, lsp_message/1]).

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

read_text(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, unicode:characters_to_binary(Binary)};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% The persisted IDE settings document, in the user's config directory
%% (XDG_CONFIG_HOME/campy/settings.json).
settings_path() ->
    Dir = filename:basedir(user_config, "campy"),
    filelib:ensure_dir(filename:join(Dir, "settings.json")),
    unicode:characters_to_binary(filename:join(Dir, "settings.json")).

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

%% The debug page's process list: on the peer when the app lives there,
%% locally otherwise.
processes_on(Node) when is_binary(Node), byte_size(Node) > 0 ->
    case rpc:call(node_name(Node), campy_runner, processes, [], 15000) of
        {badrpc, Reason} -> {error, reason(Reason)};
        Rows -> {ok, Rows}
    end;
processes_on(_) ->
    {ok, campy_runner:processes()}.

%% Decode a trace_log message forwarded by the tracer process.
trace_log_text({trace_log, Text}) -> {ok, Text};
trace_log_text(_) -> {error, nil}.

%% Decode an lsp_* message projected by the campy_lsp client into a Gleam
%% LspMessage constructor (tagged tuple) for the IDE loop, wrapped in
%% {ok, _}; {error, nil} for anything that is not a language-server message.
%% Rows keep the client's #(StartLine, EndLine, Message, Severity) projection
%% (0-based lines).
lsp_message({lsp_diagnostics, File, Rows}) ->
    {ok, {diagnostics_msg, File, Rows}};
lsp_message({lsp_completions, _File, Labels}) ->
    {ok, {completions_msg, Labels}};
lsp_message({lsp_symbols, _File, Items}) ->
    {ok, {symbols_msg, Items}};
lsp_message({lsp_definition, File, Line, Char}) ->
    {ok, {definition_msg, File, Line, Char}};
lsp_message({lsp_no_definition}) ->
    {ok, no_definition_msg};
lsp_message({lsp_down, Reason}) ->
    {ok, {down_msg, Reason}};
lsp_message(_) ->
    {error, nil}.

%% A scripted probe check rides the renderer's message channel: the loop
%% prints a PASS/FAIL line against the live state and geometry.
probe_message({probe_check, Text}) -> {ok, Text};
probe_message(_) -> {error, nil}.

inject_check(Check) ->
    self() ! {probe_check, Check},
    ok.

inject_step(Step) ->
    self() ! {probe_step, Step},
    ok.

probe_step_decode({probe_step, Step}) -> {ok, Step};
probe_step_decode(_) -> {error, nil}.

%% Keep a copy of a built beam under the versions directory for rollback.
copy_file(From, To) ->
    case file:copy(From, To) of
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Format any term (an app's state snapshot) for the debug viewer.
format_term(Term) ->
    unicode:characters_to_binary(
        string:slice(io_lib:format("~p", [Term]), 0, 800)).

%% The tracer runs ON the peer (erlang:trace accepts only local tracers);
%% campy_runner_ffi:tracer_loop forwards the events to the master pid here.
spawn_tracer(Node, Master, Label) ->
    case rpc:call(node_name(Node), erlang, spawn,
                  [campy_runner_ffi, tracer_loop, [Master, Label]]) of
        {badrpc, Reason} -> erlang:error({badrpc, Reason});
        Tracer -> Tracer
    end.

%% Trace send/receive on the actor process, with the tracer on the same node.
trace_send_receive(Node, Pid, Tracer, true) ->
    Flags = [send, 'receive', {tracer, Tracer}],
    case rpc:call(node_name(Node), erlang, trace, [Pid, true, Flags], 15000) of
        Count when is_integer(Count) ->
            {ok, nil};
        {badrpc, Reason} -> {error, reason(Reason)};
        Other -> {error, format("trace: ~p", [Other])}
    end;
trace_send_receive(_Node, _Pid, _Tracer, false) ->
    {ok, nil}.

%% Stop a tracer living on the app's node; cross-node send is fine.
stop_tracer(_Node, Tracer) ->
    Tracer ! stop,
    ok.

format(Template, Arguments) ->
    unicode:characters_to_binary(io_lib:format(Template, Arguments)).

%% Absolute process working directory; the IDE runs from its package dir
%% (gleam/apps/campy_ide_wx), three levels under the repo root.
cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
