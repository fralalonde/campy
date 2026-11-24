-module(campy_gesture_probe_ffi).
-export([run/9]).

%% Drives the loaded IDE shell document with the headless ui-testing driver:
%% pointer phases land on the designer surface and a button click reaches the
%% BEAM as `control:<wire id>:clicked` — the two input channels the loop routes.
%%
%% Note: the pointer payload carries no button or modifiers (reported gap), so
%% the probe only asserts the phases and coordinates the loop receives.

run(Title, Width, Height, Theme, Controls, CanvasId, ButtonId, ButtonX, ButtonY) ->
    {ok, Session} = campy_bridge_ffi:open_session(),
    {ok, Id} = campy_bridge_ffi:session_id(Session),
    {ok, nil} = campy_bridge_ffi:submit(
        Session, {load_ui, 1, Title, Width, Height, Theme, Controls}),
    _ = await(Id, 1, <<"ui-loaded">>, 10000),
    io:format("GESTURE_SHELL_LOADED_OK~n"),

    %% Phase 1: the surface forwards raw pointer phases at window CSS pixels.
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"press">>, 300.0, 200.0),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"move">>, 330.0, 230.0),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"release">>, 330.0, 230.0),
    Down = <<"pointer:", (integer_to_binary(CanvasId))/binary, ":down">>,
    Move = <<"pointer:", (integer_to_binary(CanvasId))/binary, ":move">>,
    Up = <<"pointer:", (integer_to_binary(CanvasId))/binary, ":up">>,
    Events = drain(1000),
    assert_payload(Events, Down, <<"300;200">>),
    assert_payload(Events, Move, <<"330;230">>),
    assert_payload(Events, Up, <<"330;230">>),
    io:format("GESTURE_POINTER_PHASES_OK~n"),

    %% Phase 2: a campy button click reaches the loop as a control event.
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"move">>, ButtonX, ButtonY),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"press">>, ButtonX, ButtonY),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"release">>, ButtonX, ButtonY),
    Clicked = <<"control:", (integer_to_binary(ButtonId))/binary, ":clicked">>,
    ClickEvents = drain(1000),
    case lists:keymember(Clicked, 1, ClickEvents) of
        true -> io:format("GESTURE_CONTROL_CLICK_OK~n");
        false -> error({missing_control_click, Clicked, ClickEvents})
    end,

    {ok, nil} = campy_bridge_ffi:close_session(Session),
    _ = await(Id, 1, <<"closed">>, 5000),
    io:format("GESTURE_PROBE_PASSED~n"),
    nil.

assert_payload(Events, Kind, Payload) ->
    case lists:keyfind(Kind, 1, Events) of
        {Kind, Payload} -> ok;
        Other -> error({unexpected_pointer_event, Kind, Payload, Other})
    end.

drain(Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    drain_until(Deadline, []).

drain_until(Deadline, Acc) ->
    pump(),
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
    pump(),
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

%% The headless ui-testing driver advances frames only when pumped; without
%% this the command drain timer never runs. Harmless on a real-window NIF.
pump() ->
    try campy_bridge_ffi:test_pump(16) catch _:_ -> ok end,
    ok.
