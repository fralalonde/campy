-module(campy_native_smoke_ffi).
-export([run/2]).

run(Source0, ApplicationSource) ->
    Source = binary:replace(Source0, <<"Campy — Search box"/utf8>>, <<"Campy native smoke">>),
    Parent = self(),
    Heartbeat = spawn_link(fun() -> heartbeat(Parent) end),
    put(beats, 0),
    {ok, Session} = campy_bridge_ffi:open_session(),
    {ok, Id} = campy_bridge_ffi:session_id(Session),
    {ok, nil} = campy_bridge_ffi:submit(Session, {load_ui, 1, Source}),
    Detail = await(Id, 1, <<"ui-loaded">>, 10000),
    true = binary:match(Detail, list_to_binary(os:getpid())) =/= nomatch,
    Before = filename:join([os:getenv("CAMPY_ROOT"), "generated", "native-before.png"]),
    {ok, nil} = campy_bridge_ffi:submit(Session, {snapshot, 1, list_to_binary(Before)}),
    _ = await(Id, 1, <<"snapshot-saved">>, 5000),
    io:format("NATIVE_SMOKE_READY pid=~s~n", [os:getpid()]),
    %% Test-only commands dispatch through Slint's normal input handling. They
    %% never target another desktop window or depend on compositor focus policy.
    {ok, nil} = campy_bridge_ffi:test_input(Session, 1, {click, 60.0, 50.0}),
    {ok, nil} = campy_bridge_ffi:test_input(Session, 1, {text, <<"gleam">>}),
    <<"gleam">> = await_query(Id, <<"gleam">>, 10000),
    {ok, nil} = campy_bridge_ffi:test_input(Session, 1, {click, 435.0, 50.0}),
    <<>> = await(Id, 1, <<"callback:search">>, 10000),
    {ok, nil} = campy_bridge_ffi:submit(Session, {resize, 1, 640, 140}),
    receive after 150 -> ok end,
    Snapshot = filename:join([os:getenv("CAMPY_ROOT"), "generated", "native-smoke.png"]),
    {ok, nil} = campy_bridge_ffi:submit(Session, {snapshot, 1, list_to_binary(Snapshot)}),
    _ = await(Id, 1, <<"snapshot-saved">>, 5000),
    %% An invalid candidate must leave generation 1 usable.
    {ok, nil} = campy_bridge_ffi:submit(Session, {load_ui, 2, <<"invalid Slint">>}),
    _ = await(Id, 2, <<"command-failed">>, 5000),
    {ok, nil} = campy_bridge_ffi:submit(Session, {read_text, 1, <<"query">>}),
    <<"gleam">> = await(Id, 1, <<"property:query">>, 5000),
    %% A valid replacement preserves the native property without BEAM rewriting it.
    {ok, nil} = campy_bridge_ffi:submit(Session, {load_ui, 2, Source}),
    _ = await(Id, 2, <<"ui-loaded">>, 5000),
    {ok, nil} = campy_bridge_ffi:submit(Session, {read_text, 2, <<"query">>}),
    <<"gleam">> = await(Id, 2, <<"property:query">>, 5000),
    {ok, nil} = campy_bridge_ffi:submit(Session, {read_text, 1, <<"query">>}),
    <<"Stale UI generation">> = await(Id, 1, <<"command-failed">>, 5000),
    spawn(fun() -> Parent ! {unauthorized, campy_bridge_ffi:submit(Session, {read_text, 2, <<"query">>})} end),
    receive {unauthorized, {error, <<"Only the session owner may issue UI commands">>}} -> ok after 3000 -> error(ownership_check_failed) end,
    {ok, nil} = campy_bridge_ffi:close_session(Session),
    _ = await(Id, 2, <<"closed">>, 5000),
    await_empty(5000),
    {ok, Closing} = campy_bridge_ffi:open_session(),
    {ok, ClosingId} = campy_bridge_ffi:session_id(Closing),
    {ok, nil} = campy_bridge_ffi:submit(Closing, {load_ui, 1, Source}),
    _ = await(ClosingId, 1, <<"ui-loaded">>, 5000),
    {ok, nil} = campy_bridge_ffi:test_input(Closing, 1, close),
    <<"reason=4">> = await(ClosingId, 1, <<"closed">>, 5000),
    await_empty(5000),
    %% The parent retains the resource: cleanup must use the process monitor,
    %% rather than relying on the resource's garbage collection.
    Child = spawn(fun() ->
        {ok, ChildSession} = campy_bridge_ffi:open_session(),
        {ok, ChildId} = campy_bridge_ffi:session_id(ChildSession),
        {ok, nil} = campy_bridge_ffi:submit(ChildSession, {load_ui, 1, Source}),
        _ = await(ChildId, 1, <<"ui-loaded">>, 5000),
        Parent ! {child_ready, ChildSession},
        receive stop -> ok end
    end),
    Monitor = monitor(process, Child),
    receive {child_ready, RetainedResource} -> put(retained_resource, RetainedResource) after 7000 -> error(owner_start_timeout) end,
    exit(Child, kill),
    receive {'DOWN', Monitor, process, Child, killed} -> ok after 3000 -> error(owner_down_timeout) end,
    await_empty(5000),
    menu_smoke(ApplicationSource),
    true = get(beats) >= 3,
    unlink(Heartbeat),
    exit(Heartbeat, shutdown),
    io:format("NATIVE_SMOKE_PASSED heartbeat=~p; input, resize, reload, generations, ownership, owner cleanup~n", [get(beats)]),
    nil.

menu_smoke(Source) ->
    {ok, MenuSession} = campy_bridge_ffi:open_session(),
    {ok, MenuId} = campy_bridge_ffi:session_id(MenuSession),
    {ok, nil} = campy_bridge_ffi:submit(MenuSession, {load_ui, 1, Source}),
    _ = await(MenuId, 1, <<"ui-loaded">>, 5000),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {click, 30.0, 24.0}),
    receive after 100 -> ok end,
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"DownArrow">>]}),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"Return">>]}),
    _ = await(MenuId, 1, <<"callback:about">>, 5000),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"Escape">>]}),
    receive after 100 -> ok end,
    MenuSnapshot = filename:join([os:getenv("CAMPY_ROOT"), "generated", "application-menu.png"]),
    {ok, nil} = campy_bridge_ffi:submit(MenuSession, {snapshot, 1, list_to_binary(MenuSnapshot)}),
    _ = await(MenuId, 1, <<"snapshot-saved">>, 5000),
    %% A field owning keyboard focus must not swallow the application shortcut.
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {click, 60.0, 90.0}),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"Control">>, <<"q">>]}),
    _ = await(MenuId, 1, <<"callback:quit">>, 5000),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"F10">>]}),
    receive after 100 -> ok end,
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"DownArrow">>]}),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"DownArrow">>]}),
    {ok, nil} = campy_bridge_ffi:test_input(MenuSession, 1, {key_combo, [<<"Return">>]}),
    _ = await(MenuId, 1, <<"callback:quit">>, 5000),
    {ok, nil} = campy_bridge_ffi:close_session(MenuSession),
    _ = await(MenuId, 1, <<"closed">>, 5000),
    io:format("MENU_SMOKE_PASSED hamburger, About, Escape, Ctrl+Q, F10, Quit~n"),
    ok.

heartbeat(Owner) ->
    receive after 20 -> Owner ! heartbeat, heartbeat(Owner) end.

await(Id, Generation, Kind, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_until(Id, Generation, Kind, Deadline).

await_until(Id, Generation, Kind, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {campy_event, Id, Generation, Kind, Payload} -> Payload;
        {campy_event, _, _, <<"runtime-failed">>, Error} -> error({native_runtime_failed, Error});
        heartbeat ->
            put(beats, case get(beats) of undefined -> 1; N -> N + 1 end),
            await_until(Id, Generation, Kind, Deadline)
    after Remaining -> error({native_event_timeout, Id, Generation, Kind})
    end.

await_query(Id, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_query_until(Id, Expected, Deadline).

await_query_until(Id, Expected, Deadline) ->
    case await_until(Id, 1, <<"callback:query-changed">>, Deadline) of
        Expected -> Expected;
        _ -> await_query_until(Id, Expected, Deadline)
    end.

await_empty(Timeout) ->
    case campy_bridge_ffi:active_sessions() of
        0 -> ok;
        _ when Timeout =< 0 -> error(native_session_leaked);
        _ -> receive after 20 -> await_empty(Timeout - 20) end
    end.

