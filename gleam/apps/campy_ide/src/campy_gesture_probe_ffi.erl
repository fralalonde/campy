-module(campy_gesture_probe_ffi).
-export([run/12]).

%% Runs the hybrid drag gesture contract against the live IDE shell:
%% marquee-from-unselected, move-from-selected, select-on-click-release.
%% The Gleam caller supplies the shell source, the wire models to push, and
%% one free-layout control's geometry (model coordinates).

run(Source, Modules, Tabs, Controls, Code, Selected, Cleared,
    Surfaces, PaneX, PaneY, WindowX, WindowY) ->
    {ok, Session} = campy_bridge_ffi:open_session(),
    {ok, Id} = campy_bridge_ffi:session_id(Session),
    {ok, nil} = campy_bridge_ffi:submit(Session, {load_ui, 1, Source}),
    _ = await(Id, 1, <<"ui-loaded">>, 10000),
    ok = push(Session, <<"module-items">>, Modules),
    ok = push(Session, <<"tab-items">>, Tabs),
    ok = push(Session, <<"control-items">>, Controls),
    ok = push(Session, <<"code-lines">>, Code),
    [{surface_spec, Target, PX, PY}] = Surfaces,
    ContentX = PaneX + WindowX, ContentY = PaneY + WindowY + 28,
    %% Calibrate: the module window's title bar is 640 wide at (WindowX,
    %% WindowY); clicking it always emits window-move-x, proving the
    %% pane-offset arithmetic lands inside the canvas.
    Calib = click(Session, 1, ContentX + 320, PaneY + WindowY + 14),
    true = lists:keymember(<<"callback:window-move-x">>, 1, Calib),
    io:format("GESTURE_CALIBRATION_OK~n"),
    %% Phase 1: drag from the unselected control past the threshold draws
    %% the marquee and commits through frame-apply; no move or drop cursor.
    press(Session, 1, ContentX + PX, ContentY + PY),
    move(Session, 1, ContentX + PX + 30, ContentY + PY + 30),
    move(Session, 1, ContentX + PX + 60, ContentY + PY + 60),
    Phase1 = release(Session, 1, ContentX + PX + 60, ContentY + PY + 60),
    true = lists:keymember(<<"callback:frame-apply">>, 1, Phase1),
    false = lists:keymember(<<"callback:move-x">>, 1, Phase1),
    false = lists:keymember(<<"callback:drag-over-x">>, 1, Phase1),
    io:format("GESTURE_MARQUEE_FROM_UNSELECTED_OK~n"),
    %% Phase 2: the same drag from a selected control arms the move instead.
    ok = push(Session, <<"control-items">>, Selected),
    Phase2 = drag(Session, 1, ContentX + PX, ContentY + PY, 45),
    true = lists:keymember(<<"callback:drag-over-x">>, 1, Phase2),
    true = lists:keymember(<<"callback:move-x">>, 1, Phase2),
    false = lists:keymember(<<"callback:frame-apply">>, 1, Phase2),
    false = lists:keymember(<<"callback:select">>, 1, Phase2),
    io:format("GESTURE_MOVE_FROM_SELECTED_OK~n"),
    %% Phase 3: press and release without movement selects on button-up.
    ok = push(Session, <<"control-items">>, Cleared),
    Phase3 = click(Session, 1, ContentX + PX, ContentY + PY),
    {_, TargetPayload} = lists:keyfind(<<"callback:select">>, 1, Phase3),
    true = TargetPayload =:= Target,
    false = lists:keymember(<<"callback:frame-apply">>, 1, Phase3),
    false = lists:keymember(<<"callback:move-x">>, 1, Phase3),
    io:format("GESTURE_SELECT_ON_RELEASE_OK~n"),
    {ok, nil} = campy_bridge_ffi:close_session(Session),
    _ = await(Id, 1, <<"closed">>, 5000),
    io:format("GESTURE_PROBE_PASSED target=~s~n", [Target]),
    nil.

push(Session, Name, Value) ->
    {ok, nil} = campy_bridge_ffi:submit(Session, {set_model, 1, Name, Value}),
    receive after 100 -> ok end.

press(Session, Gen, X, Y) ->
    {ok, nil} = campy_bridge_ffi:test_input(Session, Gen, {press, X + 0.0, Y + 0.0}).

move(Session, Gen, X, Y) ->
    {ok, nil} = campy_bridge_ffi:test_input(Session, Gen, {move, X + 0.0, Y + 0.0}),
    receive after 40 -> ok end.

release(Session, Gen, X, Y) ->
    {ok, nil} = campy_bridge_ffi:test_input(Session, Gen, {release, X + 0.0, Y + 0.0}),
    drain(400).

%% Press, two moves past the threshold, release; returns drained events.
drag(Session, Gen, X, Y, Distance) ->
    press(Session, Gen, X, Y),
    move(Session, Gen, X + Distance * 2 div 3, Y + Distance * 2 div 3),
    move(Session, Gen, X + Distance, Y + Distance),
    release(Session, Gen, X + Distance, Y + Distance).

click(Session, Gen, X, Y) ->
    press(Session, Gen, X, Y),
    release(Session, Gen, X, Y).

drain(Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    drain_until(Deadline, []).

drain_until(Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case campy_bridge_ffi:poll(min(Remaining, 1000)) of
        {some, {native_event, _, _, Kind, Payload}} ->
            drain_until(Deadline, [{Kind, Payload} | Acc]);
        none when Remaining =< 0 ->
            Acc;
        none ->
            drain_until(Deadline, Acc)
    end.

await(Id, Generation, Want, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_until(Id, Generation, Want, Deadline).

await_until(Id, Generation, Want, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case campy_bridge_ffi:poll(min(Remaining, 1000)) of
        {some, {native_event, Id, Gen, Want, Payload}} when Gen >= Generation ->
            {Want, Payload};
        {some, {native_event, _, _, <<"runtime-failed">>, Error}} ->
            error({native_runtime_failed, Error});
        {some, {native_event, _, _, _, _}} ->
            await_until(Id, Generation, Want, Deadline);
        none when Remaining =< 0 ->
            error({native_event_timeout, Id, Generation, Want});
        none ->
            await_until(Id, Generation, Want, Deadline)
    end.
