-module(campy_wx_native).
-export([
    new_app/0, destroy_app/0, frame/4, show/1, connect/2, next_message/1,
    panel/2, label/3, button/3, checkbox/3, radio/3, choice/2, listbox/2,
    textctrl/3, memo/3, slider/5, gauge/3, picture/3,
    box_sizer/1, add/4, insert/5, detach/2, set_sizer/2,
    freeze/1, thaw/1, layout/1, move/3, resize/3, set_min_size/3,
    set_label/2, set_text/2, set_int/3, set_bool/3, set_selection/3,
    set_items/3, set_enabled/2, set_visible/2, focus/1, raise/1, destroy/1,
    get_text/1, get_int/2, get_bool/2, get_selection/2,
    now_ms/0, getenv/1
]).

-include_lib("wx/include/wx.hrl").

%% Application

new_app() ->
    wx:new().

destroy_app() ->
    catch wx:destroy(),
    ok.

frame(Id, Title, Width, Height) ->
    wxFrame:new(wx:null(), Id, Title, [{size, {Width, Height}}]).

show(Ref) ->
    wxFrame:show(Ref),
    ok.

%% Widgets

panel(Parent, Id) ->
    wxPanel:new(Parent, [{winid, Id}]).

label(Parent, Id, Text) ->
    wxStaticText:new(Parent, Id, Text, []).

button(Parent, Id, Text) ->
    wxButton:new(Parent, Id, [{label, Text}]).

checkbox(Parent, Id, Text) ->
    wxCheckBox:new(Parent, Id, Text, []).

radio(Parent, Id, Text) ->
    wxRadioButton:new(Parent, Id, Text, []).

choice(Parent, Id) ->
    wxChoice:new(Parent, Id, []).

listbox(Parent, Id) ->
    wxListBox:new(Parent, Id, []).

textctrl(Parent, Id, Value) ->
    wxTextCtrl:new(Parent, Id, [{value, Value}]).

memo(Parent, Id, Value) ->
    wxTextCtrl:new(Parent, Id, [{value, Value}, {style, ?wxTE_MULTILINE}]).

slider(Parent, Id, Value, Min, Max) ->
    wxSlider:new(Parent, Id, Value, Min, Max, []).

gauge(Parent, Id, Range) ->
    wxGauge:new(Parent, Id, Range, []).

picture(Parent, Id, Path) ->
    try
        Image = wxImage:new(Path),
        Bitmap = wxBitmap:new(Image),
        wxStaticBitmap:new(Parent, Id, Bitmap, [])
    catch
        _:_ -> wxStaticText:new(Parent, Id, <<"[missing image]">>, [])
    end.

%% Layout

box_sizer(Vertical) ->
    case Vertical of
        true -> wxBoxSizer:new(?wxVERTICAL);
        false -> wxBoxSizer:new(?wxHORIZONTAL)
    end.

add(Sizer, Child, Border, Expand) ->
    wxSizer:add(Sizer, Child, sizer_options(Border, Expand)),
    ok.

insert(Sizer, Index, Child, Border, Expand) ->
    wxSizer:insert(Sizer, Index, Child, sizer_options(Border, Expand)),
    ok.

detach(Sizer, Child) ->
    _ = wxSizer:detach(Sizer, Child),
    ok.

sizer_options(Border, Expand) ->
    Flag =
        case Expand of
            true -> ?wxEXPAND;
            false -> 0
        end,
    [{flag, Flag}, {border, Border}].

set_sizer(Window, Sizer) ->
    wxWindow:setSizer(Window, Sizer),
    ok.

freeze(Ref) ->
    wxWindow:freeze(Ref),
    ok.

thaw(Ref) ->
    wxWindow:thaw(Ref),
    ok.

layout(Ref) ->
    wxWindow:layout(Ref),
    ok.

move(Ref, X, Y) ->
    wxWindow:move(Ref, {X, Y}),
    ok.

resize(Ref, Width, Height) when Width > 0, Height > 0 ->
    wxWindow:setSize(Ref, {Width, Height}),
    ok;
resize(_Ref, _Width, _Height) ->
    ok.

set_min_size(Ref, Width, Height) when Width > 0, Height > 0 ->
    wxWindow:setMinSize(Ref, {Width, Height}),
    ok;
set_min_size(_Ref, _Width, _Height) ->
    ok.

%% Properties

set_label(Ref, Text) ->
    wxWindow:setLabel(Ref, Text),
    ok.

set_text(Ref, Text) ->
    wxTextCtrl:setValue(Ref, Text),
    ok.

set_int(Ref, <<"slider">>, Value) ->
    wxSlider:setValue(Ref, Value),
    ok;
set_int(Ref, <<"progress">>, Value) ->
    % wxGauge setters accept a value; the position may lag, which is fine.
    catch wxGauge:setValue(Ref, Value),
    ok;
set_int(_Ref, _Kind, _Value) ->
    ok.

set_bool(Ref, <<"checkbox">>, Value) ->
    wxCheckBox:setValue(Ref, Value),
    ok;
set_bool(Ref, <<"radio">>, Value) ->
    wxRadioButton:setValue(Ref, Value),
    ok;
set_bool(_Ref, _Kind, _Value) ->
    ok.

set_selection(Ref, <<"choice">>, Index) ->
    wxChoice:setSelection(Ref, Index),
    ok;
set_selection(Ref, <<"list">>, Index) ->
    wxListBox:setSelection(Ref, Index),
    ok;
set_selection(_Ref, _Kind, _Index) ->
    ok.

set_items(Ref, <<"choice">>, Items) ->
    wxChoice:clear(Ref),
    lists:foreach(fun(Item) -> wxChoice:append(Ref, Item) end, Items),
    ok;
set_items(Ref, <<"list">>, Items) ->
    wxListBox:clear(Ref),
    lists:foreach(fun(Item) -> wxListBox:append(Ref, Item) end, Items),
    ok;
set_items(_Ref, _Kind, _Items) ->
    ok.

set_enabled(Ref, Enabled) ->
    wxWindow:enable(Ref, [{enable, Enabled}]),
    ok.

set_visible(Ref, Visible) ->
    wxWindow:show(Ref, [{show, Visible}]),
    ok.

focus(Ref) ->
    wxWindow:setFocus(Ref),
    ok.

raise(Ref) ->
    wxWindow:raise(Ref),
    ok.

destroy(Ref) ->
    catch wxWindow:destroy(Ref),
    ok.

%% Events

connect(Ref, <<"window">>) ->
    wxFrame:connect(Ref, close_window, []);
connect(Ref, <<"button">>) ->
    wxButton:connect(Ref, command_button_clicked, []);
connect(Ref, <<"checkbox">>) ->
    wxCheckBox:connect(Ref, command_checkbox_clicked, []);
connect(Ref, <<"radio">>) ->
    wxRadioButton:connect(Ref, command_radiobutton_selected, []);
connect(Ref, <<"text">>) ->
    wxTextCtrl:connect(Ref, command_text_updated, []);
connect(Ref, <<"memo">>) ->
    wxTextCtrl:connect(Ref, command_text_updated, []);
connect(Ref, <<"choice">>) ->
    wxChoice:connect(Ref, command_choice_selected, []);
connect(Ref, <<"list">>) ->
    wxListBox:connect(Ref, command_listbox_selected, []);
connect(Ref, <<"slider">>) ->
    wxSlider:connect(Ref, command_slider_updated, []);
connect(_Ref, _Kind) ->
    ok.

%% The process that owns the widgets receives `#wx{}` records. This is the
%% single receive point: wx events are normalised, everything else is handed
%% back untouched so the caller can run its own message protocol.

next_message(Timeout) ->
    receive
        {wx, Id, _Obj, _UserData, Event} ->
            {wx_event, Id, event_type(Event)};
        Other ->
            {other, Other}
    after timeout(Timeout) ->
        idle
    end.

timeout(Milliseconds) when is_integer(Milliseconds), Milliseconds < 0 -> infinity;
timeout(Milliseconds) when is_integer(Milliseconds) -> Milliseconds;
timeout(_) -> infinity.

event_type(Event) when is_tuple(Event) ->
    case element(1, Event) of
        wxCommand -> <<"command">>;
        wxClose -> <<"close">>;
        wxSize -> <<"size">>;
        wxPaint -> <<"paint">>;
        wxMouse -> <<"mouse">>;
        _ -> <<"other">>
    end;
event_type(_) ->
    <<"other">>.

%% Values read back after a command event.

get_text(Ref) ->
    unicode:characters_to_binary(wxTextCtrl:getValue(Ref)).

get_int(Ref, <<"slider">>) ->
    wxSlider:getValue(Ref);
get_int(Ref, <<"progress">>) ->
    wxGauge:getValue(Ref);
get_int(_Ref, _Kind) ->
    0.

get_bool(Ref, <<"checkbox">>) ->
    wxCheckBox:getValue(Ref);
get_bool(Ref, <<"radio">>) ->
    wxRadioButton:getValue(Ref);
get_bool(_Ref, _Kind) ->
    false.

get_selection(Ref, <<"choice">>) ->
    wxChoice:getSelection(Ref);
get_selection(Ref, <<"list">>) ->
    wxListBox:getSelection(Ref);
get_selection(_Ref, _Kind) ->
    -1.

now_ms() ->
    erlang:monotonic_time(millisecond).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.
