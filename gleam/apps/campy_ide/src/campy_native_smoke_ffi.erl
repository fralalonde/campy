-module(campy_native_smoke_ffi).
-export([run/10]).

%% Native smoke over protocol v2: document load, synthetic input, a text read,
%% a resize, a generation-guarded reload, session ownership, and close.
%%
%% The old Slint scene snapshot is gone (protocol v2 has no Snapshot command);
%% Z4.1 owns the headless scene-dump goldens.

run(Title, Width, Height, Theme, Controls, ClickId, ClickX, ClickY, LabelId, LabelText) ->
    {ok, Session} = campy_bridge_ffi:open_session(),
    {ok, Id} = campy_bridge_ffi:session_id(Session),
    {ok, nil} = campy_bridge_ffi:submit(
        Session, {load_ui, 1, Title, Width, Height, Theme, Controls}),
    Detail = await(Id, 1, <<"ui-loaded">>, 10000),
    true = is_binary(Detail),
    io:format("NATIVE_SMOKE_LOADED ~s~n", [Detail]),

    %% A designed button answers a real pointer click.
    {ok, _} = campy_bridge_ffi:test_pump(16),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"press">>, ClickX, ClickY),
    {ok, nil} = campy_bridge_ffi:test_pointer(<<"release">>, ClickX, ClickY),
    Clicked = <<"control:", (integer_to_binary(ClickId))/binary, ":clicked">>,
    case lists:keymember(Clicked, 1, drain(1000)) of
        true -> io:format("NATIVE_SMOKE_CLICK_OK~n");
        false -> error({missing_click, Clicked})
    end,

    %% Read a label's text back from the live document.
    LabelText = read_text(Session, Id, 1, LabelId),
    io:format("NATIVE_SMOKE_READ_OK~n"),

    %% A platform resize keeps the document live.
    {ok, nil} = campy_bridge_ffi:test_resize(800.0, 480.0),
    %% Test input and UI commands have separate asynchronous queues. Wait for
    %% the resize itself, otherwise close may overtake it and leave the test
    %% driver delivering input to a window that no longer exists.
    <<"800;480">> = await(Id, 1, <<"size">>, 5000),

    %% A non-increasing generation is rejected without touching the document.
    {ok, nil} = campy_bridge_ffi:submit(
        Session, {load_ui, 1, Title, Width, Height, Theme, Controls}),
    <<"UI generation must increase">> = await(Id, 1, <<"command-failed">>, 5000),

    %% A newer generation replaces it and the document is still readable.
    {ok, nil} = campy_bridge_ffi:submit(
        Session, {load_ui, 2, Title, Width, Height, Theme, Controls}),
    _ = await(Id, 2, <<"ui-loaded">>, 5000),
    LabelText = read_text(Session, Id, 2, LabelId),

    %% Only the owning process may drive the session.
    Parent = self(),
    spawn(fun() ->
        Parent ! {unauthorized, campy_bridge_ffi:submit(
            Session, {read_text, 2, LabelId, <<"text">>})}
    end),
    receive
        {unauthorized, {error, <<"Only the session owner may issue UI commands">>}} -> ok
    after 3000 -> error(ownership_check_failed)
    end,

    {ok, nil} = campy_bridge_ffi:close_session(Session),
    _ = await(Id, 2, <<"closed">>, 5000),
    io:format("NATIVE_SMOKE_PASSED input, read, resize, generations, ownership, close~n"),
    nil.

read_text(Session, Id, Generation, Control) ->
    {ok, nil} = campy_bridge_ffi:submit(
        Session, {read_text, Generation, Control, <<"text">>}),
    await(Id, Generation, read_kind(Control), 5000).

read_kind(Control) ->
    <<"read:", (integer_to_binary(Control))/binary, ":text">>.

await(Id, Generation, Kind, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_until(Id, Generation, Kind, Deadline).

await_until(Id, Generation, Kind, Deadline) ->
    pump(),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case campy_bridge_ffi:poll(min(Remaining, 1000)) of
        {some, {native_event, Id, Gen, Kind, Payload}} when Gen >= Generation ->
            Payload;
        {some, {native_event, _, _, <<"runtime-failed">>, Error}} ->
            error({native_runtime_failed, Error});
        {some, {native_event, _, _, _, _}} ->
            await_until(Id, Generation, Kind, Deadline);
        none when Remaining =< 0 ->
            error({native_event_timeout, Id, Generation, Kind});
        none ->
            await_until(Id, Generation, Kind, Deadline)
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

%% The headless ui-testing driver advances frames only when pumped; without
%% this the command drain timer never runs. Harmless on a real-window NIF.
pump() ->
    try campy_bridge_ffi:test_pump(16) catch _:_ -> ok end,
    ok.
