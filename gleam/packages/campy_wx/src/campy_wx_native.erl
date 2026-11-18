-module(campy_wx_native).
-export([
    new_app/0, destroy_app/0, frame/4, show/1, connect/2, next_message/1,
    panel/2, label/3, button/3, checkbox/3, radio/3, choice/2, listbox/2,
    textctrl/3, memo/3, slider/5, gauge/3, picture/3,
    box_sizer/1, add/5, insert/6, detach/2, set_sizer/2, layout_sizer/2,
    menubar/0, menu/0, menuitem/3, append_menu/3, set_menubar/2,
    toolbar/1, tool/3, tool/4, tool_separator/1, realize_toolbar/1,
    palette/2, palette_owner/1,
    statusbar/1, set_status/2,
    notebook/2, page/3, notebook_selection/1, select_page/2,
    tree/2, tree_set/2, tree_selected_key/1,
    grid/2, grid_set/2, grid_configure/5, grid_cell/1,
    grid_number_cell/4, grid_text_cell/3, grid_read_only/4,
    editor/2, editor_set/3, editor_show_end/1, editor_gleam/1,
    editor_style_gleam/2, editor_get_text/1, editor_caret/1, editor_goto/3,
    editor_diagnostics/2, editor_autocomplete/2,
    editor_scheme/2, editor_font/3,
    editor_clipboard/2,
    settings_dialog/7, agent_dialog/5,
    grab_show/6, grab_move/5, grab_hide/1, grab_owner/1, grab_list/0,
    grab_next_id/0, form_plate_set/6, form_plate_get/1, form_plate_rect/1,
    form_plate_retain/1,
    plate_owner/1, pointer_in/1, enum_popup_wx_id/0, enum_popup_anchored/0,
    widget_report/1,
    view_wx_id/2, view_ref/2, pointer_override/2, pointer_clear/0,
    grab_strip_wx_id/1, grab_strip_info/2, palette_tool/1, widget_icon/1,
    plate_wx_id/1, enum_popup_list/0, enum_popup_select/1, inspector_cell/3,
    child_count/1, null_ref/0, toolbar_stats/1, debug_str/1, inject_mouse/6, inject_command/3, inject_grid_select/3,
    inject_strip_press/3, inject_plate_press/3, inject_tool_press/1, snapshot/2,
    inject_list_pick/4,
    grid_choice_cell/4,
    open_dialog/2, save_dialog/3, show_message/3,
    set_tooltip/2,
    canvas/2, paint_canvas/7, connect_design/2,
    capture/1, release/1, release_capture/0, set_cursor/2, set_shortcuts/2,
    freeze/1, thaw/1, layout/1, move/3, resize/3, set_min_size/3, client_size/1, widget_rect/1,
    set_label/2, set_text/2, set_int/3, set_bool/3, set_selection/3,
    set_items/3, set_enabled/2, set_visible/2, set_background/4, set_background_hex/2, refresh_window/1, update_window/1, focus/1,
    focus_ignoring_children/1, set_editable/2, raise/1, destroy/1, apply_shortcuts/1,
    get_text/1, get_int/2, get_bool/2, get_selection/2,
    now_ms/0, getenv/1, editor_word_at/1, editor_replace_line/3, editor_jump_list/2,
    editor_jumped/1, editor_connect_jump/1
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

%% ---------------------------------------------------------------------------
%% Selection grab strips. Four thin yellow plates surround the selected
%% widget - top, bottom, left, right - protruding 3px. They never overlap the
%% widget itself (windowless widgets like labels cannot be raised above a
%% sibling panel), so nothing is ever hidden. Each strip remembers its offset
%% so press coordinates convert into the widget's space.
%% ---------------------------------------------------------------------------

grab_map() ->
    case get(campy_grabs) of
        undefined -> #{};
        M -> M
    end.

grab_ids_map() ->
    case get(campy_grab_ids) of
        undefined -> #{};
        M -> M
    end.

strip_layouts(X, Y, W, H) ->
    [
        {X - 3, Y - 3, W + 6, 3, -3, -3},
        {X - 3, Y + H, W + 6, 3, -3, H},
        {X - 3, Y, 3, H, -3, 0},
        {X + W, Y, 3, H, W, 0}
    ].

%% ViewId -> [{Ref, WxId, Dx, Dy}] for its four strips; WxId -> ViewId.
grab_show(ViewId, Parent, X, Y, W, H) ->
    grab_hide(ViewId),
    Made = lists:map(
        fun({SX, SY, SW, SH, DX, DY}) ->
            WxId = grab_next_id(),
            Ref = wxPanel:new(Parent, [{winid, WxId}]),
            wxPanel:setBackgroundColour(Ref, {255, 221, 0}),
            wxPanel:connect(Ref, left_down, []),
            wxPanel:connect(Ref, motion, []),
            wxPanel:connect(Ref, left_up, []),
            wxWindow:move(Ref, {SX, SY}),
            wxWindow:setSize(Ref, {SW, SH}),
            wxWindow:raise(Ref),
            {Ref, WxId, DX, DY}
        end,
        strip_layouts(X, Y, W, H)
    ),
    put(campy_grabs, maps:put(ViewId, Made, grab_map())),
    put(
        campy_grab_ids,
        lists:foldl(
            fun({_, WxId, _, _}, Acc) -> maps:put(WxId, ViewId, Acc) end,
            grab_ids_map(),
            Made
        )
    ),
    ok.

%% Reposition the strips around a (possibly moved/resized) widget.
grab_move(ViewId, X, Y, W, H) ->
    case maps:find(ViewId, grab_map()) of
        {ok, Strips} ->
            Updated = lists:map(
                fun({{SX, SY, SW, SH, DX, DY}, {Ref, WxId, _, _}}) ->
                    wxWindow:move(Ref, {SX, SY}),
                    case is_integer(SW) andalso SW > 0 andalso
                         is_integer(SH) andalso SH > 0
                    of
                        true -> wxWindow:setSize(Ref, {SW, SH});
                        false -> ok
                    end,
                    {Ref, WxId, DX, DY}
                end,
                lists:zip(strip_layouts(X, Y, W, H), Strips)
            ),
            put(campy_grabs, maps:put(ViewId, Updated, grab_map())),
            ok;
        error ->
            ok
    end.

grab_hide(ViewId) ->
    case maps:find(ViewId, grab_map()) of
        {ok, Strips} ->
            lists:foreach(
                fun({Ref, WxId, _, _}) ->
                    catch wxWindow:destroy(Ref),
                    put(campy_grab_ids, maps:remove(WxId, grab_ids_map()))
                end,
                Strips
            ),
            put(campy_grabs, maps:remove(ViewId, grab_map())),
            ok;
        error ->
            ok
    end.

%% Which widget a strip press belongs to, and the strip's offset into that
%% widget's space (strip-relative + offset = widget-relative).
grab_owner(WxId) ->
    case maps:find(WxId, grab_ids_map()) of
        {ok, ViewId} ->
            case maps:find(ViewId, grab_map()) of
                {ok, Strips} ->
                    case
                        lists:search(
                            fun({_, Id, _, _}) -> Id =:= WxId end, Strips
                        )
                    of
                        {value, {_, _, DX, DY}} -> {ok, {ViewId, DX, DY}};
                        false -> {ok, {ViewId, 0, 0}}
                    end;
                error ->
                    {ok, {ViewId, 0, 0}}
            end;
        error ->
            {error, nil}
    end.

grab_list() ->
    maps:keys(grab_map()).

%% Grab ids live in their own range, away from the view widget ids (main
%% shell from 1001, run window from 900000).
grab_next_id() ->
    Current = case get(campy_grab_next) of
        undefined -> 400000;
        N -> N
    end,
    put(campy_grab_next, Current + 1),
    Current.

%% ---------------------------------------------------------------------------
%% The form plate: the form itself as a selectable surface. A white panel on
%% the design canvas at the form's editor position, kept below the controls
%% (it is the form's body: clicking it selects the form, dragging moves it).
%% ---------------------------------------------------------------------------

plate_map() ->
    case get(campy_plates) of
        undefined -> #{};
        M -> M
    end.

plate_ids_map() ->
    case get(campy_plate_ids) of
        undefined -> #{};
        M -> M
    end.

%% Create or move the plate for a form root; its wx id routes presses to the
%% form's id with plate-relative coordinates. The plate panel itself is
%% pre-created with the canvas (see canvas/2): GTK stacks child windows by
%% CREATION order and Raise/Lower are no-ops for children on this build, so
%% a plate created after the controls would sit on top of them forever.
form_plate_set(ViewId, Parent, X, Y, W, H) ->
    CanvasPlates = canvas_plate_map(),
    {Ref, WxId, Rekey} = case maps:find(ViewId, plate_map()) of
        {ok, {R, Id}} ->
            {R, Id, none};
        error ->
            case maps:find(Parent, CanvasPlates) of
                {ok, {PR, PId, OldView}} ->
                    %% Re-key the canvas's pre-made plate to this form.
                    case OldView of
                        undefined -> ok;
                        _ ->
                            put(campy_plates,
                                maps:remove(OldView, plate_map())),
                            put(campy_plate_ids,
                                maps:remove(PId, plate_ids_map()))
                    end,
                    {PR, PId, {some, OldView}};
                error ->
                    %% No pre-made plate (foreign parent): last resort,
                    %% created last — above the controls.
                    Id = grab_next_id(),
                    R0 = wxPanel:new(Parent,
                                    [{winid, Id},
                                     {style, ?wxBORDER_SIMPLE bor
                                             ?wxFULL_REPAINT_ON_RESIZE}]),
                    wxPanel:setBackgroundColour(R0, {255, 255, 255}),
                    wxPanel:connect(R0, left_down, []),
                    wxPanel:connect(R0, motion, []),
                    wxPanel:connect(R0, left_up, []),
                    {R0, Id, none}
            end
    end,
    case Rekey of
        {some, Old} when Old =/= undefined, Old =/= ViewId ->
            case os:getenv("CAMPY_DUMP") of
                "1" ->
                    io:format("[dump] plate re-keyed ~s -> ~s at ~p,~p ~px~p~n",
                              [Old, ViewId, X, Y, W, H]);
                _ -> ok
            end;
        _ -> ok
    end,
    wxWindow:move(Ref, {X, Y}),
    wxWindow:setSize(Ref, {W, H}),
    %% No show here: the pre-made plate is shown at canvas creation so the
    %% design controls (shown after it) stay above it in GTK's stack.
    put(campy_plates, maps:put(ViewId, {Ref, WxId}, plate_map())),
    put(campy_plate_ids, maps:put(WxId, ViewId, plate_ids_map())),
    put(campy_canvas_plates,
        maps:put(Parent, {Ref, WxId, ViewId}, CanvasPlates)),
    ok.

canvas_plate_map() ->
    case get(campy_canvas_plates) of
        undefined -> #{};
        M -> M
    end.

form_plate_get(ViewId) ->
    case maps:find(ViewId, plate_map()) of
        {ok, {Ref, _}} -> {ok, Ref};
        error -> {error, nil}
    end.

%% Destroy every plate except the one for ViewId. Switching modules otherwise
%% stacks white plates on the canvas forever.
form_plate_retain(ViewId) ->
    Plates = plate_map(),
    lists:foreach(
        fun({Key, {Ref, WxId}}) when Key =/= ViewId ->
                catch wxWindow:destroy(Ref),
                put(campy_plate_ids, maps:remove(WxId, plate_ids_map()));
           (_) ->
                ok
        end,
        maps:to_list(Plates)
    ),
    put(campy_plates, maps:filter(fun(Key, _) -> Key =:= ViewId end, Plates)),
    ok.

form_plate_rect(ViewId) ->
    case maps:find(ViewId, plate_map()) of
        {ok, {Ref, _}} ->
            case wxWindow:getRect(Ref) of
                {X, Y, W, H} -> {ok, {X, Y, W, H}};
                _ -> {error, nil}
            end;
        error ->
            {error, nil}
    end.

plate_owner(WxId) ->
    case maps:find(WxId, plate_ids_map()) of
        {ok, ViewId} -> {ok, ViewId};
        error -> {error, nil}
    end.

%% Where the pointer currently is, in a window's client coordinates: drags
%% read the true pointer so a moving widget cannot shift the coordinate base.
pointer_in(Ref) ->
    case get(campy_pointer) of
        {X, Y} ->
            {X, Y};
        undefined ->
            {SX, SY} = wx_misc:getMousePosition(),
            wxWindow:screenToClient(Ref, {SX, SY})
    end.

%% ---------------------------------------------------------------------------
%% Probe support: scripted tests inject synthetic wx events into the owner's
%% mailbox, so the REAL message pump and the REAL IDE loop drive every
%% gesture. Helpers expose shell internals and warp the pointer for
%% deterministic drags.
%% ---------------------------------------------------------------------------

null_ref() ->
    wx:null().

view_wx_id(Shell, ViewId) ->
    {shell, _, _, Widgets, _, _, _, _} = Shell,
    case maps:find(ViewId, Widgets) of
        {ok, {widget, _, _, WxId, _, _, _, _, _, _, _, _, _}} ->
            {ok, WxId};
        error ->
            {error, nil}
    end.

view_ref(Shell, ViewId) ->
    {shell, _, _, Widgets, _, _, _, _} = Shell,
    case maps:find(ViewId, Widgets) of
        {ok, {widget, Ref, _, _, _, _, _, _, _, _, _, _, _}} -> {ok, Ref};
        error -> {error, nil}
    end.

%% Deterministic drags in scripted tests: override what `pointer_in` reads
%% (the real pointer position is used when no override is set).
pointer_override(X, Y) ->
    put(campy_pointer, {X, Y}),
    ok.

pointer_clear() ->
    erase(campy_pointer),
    ok.

grab_strip_wx_id(ViewId) ->
    case maps:find(ViewId, grab_map()) of
        {ok, [{_, WxId, _, _} | _]} -> {ok, WxId};
        _ -> {error, nil}
    end.

%% A grab strip by index: {WxId, Dx, Dy} (0=top, 1=bottom, 2=left, 3=right).
grab_strip_info(ViewId, Index) ->
    case maps:find(ViewId, grab_map()) of
        {ok, Strips} ->
            case lists:nth(Index + 1, Strips) of
                {_, WxId, DX, DY} -> {ok, {WxId, DX, DY}};
                _ -> {error, nil}
            end;
        error ->
            {error, nil}
    end.

palette_tool(Kind) ->
    case
        lists:search(
            fun({_, K}) -> K =:= Kind end, maps:to_list(palette_ids_map())
        )
    of
        {value, {Id, _}} -> {ok, Id};
        false -> {error, nil}
    end.

plate_wx_id(ViewId) ->
    case maps:find(ViewId, plate_map()) of
        {ok, {_, WxId}} -> {ok, WxId};
        error -> {error, nil}
    end.

enum_popup_list() ->
    case get(campy_enum_popup) of
        {_, List, _, _, _, _, _} -> {ok, List};
        undefined -> {error, nil}
    end.

enum_popup_select(Index) ->
    case get(campy_enum_popup) of
        {_, List, _, _, _, _, _} ->
            wxListBox:select(List, Index),
            ok;
        undefined ->
            ok
    end.

%% Is the open dropdown anchored at the cell it belongs to?
debug_str(Term) ->
    unicode:characters_to_binary(io_lib:format("~200p", [Term])).

enum_popup_anchored() ->
    case get(campy_enum_popup) of
        {Popup, _, _, _, _, SX, SY} ->
            case wxWindow:getScreenPosition(Popup) of
                {SX, SY} -> {ok, true};
                {X, Y} -> {ok, {X, Y}}
            end;
        undefined ->
            {error, nil}
    end.

enum_popup_wx_id() ->
    case get(campy_enum_popup) of
        {_, List, _, _, _, _, _} -> {ok, wxWindow:getId(List)};
        undefined -> {error, nil}
    end.

inspector_cell(Shell, Row, Col) ->
    {shell, _, _, Widgets, _, _, _, _} = Shell,
    case maps:find(<<"inspector">>, Widgets) of
        {ok, {widget, Ref, _, _, _, _, _, _, _, _, _, _, _}} ->
            unicode:characters_to_binary(wxGrid:getCellValue(Ref, Row, Col));
        error ->
            <<>>
    end.

child_count(Ref) ->
    length(wxWindow:getChildren(Ref)).

inject_mouse(WxId, Ref, Type, X, Y, Ctrl) ->
    self() ! {wx, WxId, Ref, [],
              {wxMouse, binary_to_atom(Type, utf8), X, Y, false, false, false,
               Ctrl, false, false}},
    ok.

inject_command(WxId, Type, Int) ->
    self() ! {wx, WxId, wx:null(), [],
              {wxCommand, binary_to_atom(Type, utf8), <<>>, Int, []}},
    ok.

%% Strip and plate presses (the pump routes them by wx id; the Obj payload
%% is irrelevant for mouse attribution).
inject_strip_press(WxId, X, Y) ->
    self() ! {wx, WxId, wx:null(), [],
              {wxMouse, left_down, X, Y, false, false, false, false, false,
               false}},
    ok.

inject_plate_press(WxId, X, Y) ->
    self() ! {wx, WxId, wx:null(), [],
              {wxMouse, left_down, X, Y, false, false, false, false, false,
               false}},
    ok.

inject_tool_press(WxId) ->
    self() ! {wx, WxId, wx:null(), [],
              {wxCommand, command_menu_selected, <<>>, WxId, []}},
    ok.

%% Toolbar diagnostics for the probe: do the bitmap tools actually exist
%% and how big did the toolbar become?
toolbar_stats(ToolBar) ->
    {wxToolBar:getToolSize(ToolBar), wxToolBar:getToolBitmapSize(ToolBar),
     wxWindow:getClientSize(ToolBar), wxWindow:getSize(ToolBar)}.

%% Capture a window's on-screen content into a PNG (probe diagnostics).
snapshot(Ref, Path) ->
    {X, Y} = wxWindow:getScreenPosition(Ref),
    {W, H} = wxWindow:getClientSize(Ref),
    Screen = wxScreenDC:new(),
    Bmp = wxBitmap:new(W, H),
    Mem = wxMemoryDC:new(),
    wxMemoryDC:selectObject(Mem, Bmp),
    %% blit(DEST_DC, {Xdest,Ydest}, {W,H}, SOURCE_DC, {Xsrc,Ysrc}): copy the
    %% window's screen rectangle into the memory bitmap.
    catch wxDC:blit(Mem, {0, 0}, {W, H}, Screen, {X, Y}),
    Null = wxBitmap:new(1, 1),
    wxMemoryDC:selectObject(Mem, Null),
    Image = wxBitmap:convertToImage(Bmp),
    case wxImage:saveFile(Image, unicode:characters_to_list(Path),
                          <<"image/png">>)
    of
        true -> ok;
        _ -> ok
    end,
    wxImage:destroy(Image),
    wxMemoryDC:destroy(Mem),
    wxBitmap:destroy(Null),
    wxBitmap:destroy(Bmp),
    wxScreenDC:destroy(Screen),
    ok.

inject_grid_select(Ref, Row, Col) ->
    self() ! {wx, wxWindow:getId(Ref), Ref, [],
              {wxGrid, grid_select_cell, Row, Col, false, {0, 0}, false}},
    ok.

inject_list_pick(ListId, List, Text, Int) ->
    self() ! {wx, ListId, List, [],
              {wxCommand, command_listbox_selected, Text, Int, []}},
    ok.

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
        Resolved = resolve_picture(Path),
        Image = wxImage:new(Resolved),
        Bitmap = wxBitmap:new(Image),
        wxImage:destroy(Image),
        wxStaticBitmap:new(Parent, Id, Bitmap, [])
    catch
        _:_ -> wxStaticText:new(Parent, Id, <<"[missing image]">>, [])
    end.

%% Form assets live next to the project: a bare relative picture path
%% resolves against CAMPY_PROJECT (set by scripts/workspace.py) before the
%% IDE's own working directory.
resolve_picture(Path) ->
    Native = unicode:characters_to_list(Path),
    case filelib:is_regular(Native) of
        true ->
            Native;
        false ->
            Project = case os:getenv("CAMPY_PROJECT") of
                          false -> ".";
                          Value -> Value
                      end,
            ProjectPath = filename:join(Project, Native),
            case filelib:is_regular(ProjectPath) of
                true -> ProjectPath;
                false -> Native
            end
    end.

%% Layout

box_sizer(Vertical) ->
    case Vertical of
        true -> wxBoxSizer:new(?wxVERTICAL);
        false -> wxBoxSizer:new(?wxHORIZONTAL)
    end.

add(Sizer, Child, Border, Expand, Proportion) ->
    wxSizer:add(Sizer, Child, sizer_options(Border, Expand, Proportion)),
    ok.

insert(Sizer, Index, Child, Border, Expand, Proportion) ->
    wxSizer:insert(Sizer, Index, Child, sizer_options(Border, Expand, Proportion)),
    ok.

detach(Sizer, Child) ->
    _ = wxSizer:detach(Sizer, Child),
    ok.

sizer_options(Border, Expand, Proportion) ->
    Flag =
        case Expand of
            true -> ?wxEXPAND;
            false -> 0
        end,
    [{proportion, Proportion}, {flag, Flag}, {border, Border}].

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

%% wxWindow:layout/1 recurses through children windows but a panel that was
%% absolutely positioned under a free-layout parent never gets its own sizer
%% recalculated; wxSizer:layout/1 sizes the children directly.
layout_sizer(Window, Sizer) ->
    wxSizer:layout(Sizer),
    wxWindow:layout(Window),
    ok.

move(Ref, X, Y) ->
    wxWindow:move(Ref, {X, Y}),
    ok.

%% The client area a free-layout parent offers its children, as {W, H}. The
%% align docking pass resolves against this, so panes follow resizes.
client_size(Ref) ->
    {W, H} = wxWindow:getClientSize(Ref),
    {W, H}.

resize(Ref, Width, Height) when Width > 0, Height > 0 ->
    wxWindow:setSize(Ref, {Width, Height}),
    ok;
resize(_Ref, _Width, _Height) ->
    ok.

%% A widget's current on-screen rectangle {X, Y, W, H} in its parent's
%% coordinates; {error, nil} when the window is not yet shown.
widget_rect(Ref) ->
    case wxWindow:getRect(Ref) of
        {X, Y, W, H} when W > 0, H > 0 -> {ok, {X, Y, W, H}};
        _ -> {error, nil}
    end.

set_min_size(Ref, Width, Height) ->
    {CurrentWidth, CurrentHeight} = wxWindow:getMinSize(Ref),
    W = case Width > 0 of true -> Width; false -> CurrentWidth end,
    H = case Height > 0 of true -> Height; false -> CurrentHeight end,
    case W > 0 orelse H > 0 of
        true -> wxWindow:setMinSize(Ref, {W, H});
        false -> ok
    end,
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
    %% A filled list box must not auto-select its first row: the Events list
    %% would otherwise open a handler just because its page became visible.
    catch wxListBox:setSelection(Ref, -1),
    ok;
set_items(_Ref, _Kind, _Items) ->
    ok.

set_enabled(Ref, Enabled) ->
    wxWindow:enable(Ref, [{enable, Enabled}]),
    ok.

set_visible(Ref, Visible) ->
    wxWindow:show(Ref, [{show, Visible}]),
    ok.

refresh_window(Ref) ->
    wxWindow:refresh(Ref),
    ok.

%% Refresh queues an expose; update flushes the pending paint immediately.
update_window(Ref) ->
    wxWindow:update(Ref),
    ok.

%% Refresh queues an expose; update flushes the pending paint immediately,
%% which is what text changed outside a wx event needs.
set_background(Ref, R, G, B) ->
    wxWindow:setBackgroundColour(Ref, {R, G, B}),
    wxWindow:refresh(Ref),
    ok.

%% Background colour from a "#rrggbb" scheme value (the design canvas panel;
%% the buffered paint DC covers it anyway, but a matching panel avoids a
%% light flash between layout and paint).
set_background_hex(Ref, Hex) ->
    wxWindow:setBackgroundColour(Ref, hex_rgb(Hex, {245, 246, 248})),
    wxWindow:refresh(Ref),
    ok.

focus(Ref) ->
    wxWindow:setFocus(Ref),
    ok.

focus_ignoring_children(Ref) ->
    catch wxPanel:setFocusIgnoringChildren(Ref),
    ok.

set_editable(Ref, Editable) ->
    catch wxTextCtrl:setEditable(Ref, Editable),
    ok.

set_tooltip(Ref, Text) ->
    catch wxWindow:setToolTip(Ref, Text),
    ok.


raise(Ref) ->
    wxWindow:raise(Ref),
    ok.

destroy(Ref) ->
    catch wxWindow:destroy(Ref),
    ok.

%% Chrome

menubar() ->
    wxMenuBar:new().

menu() ->
    wxMenu:new().

menuitem(Menu, Id, Label) ->
    wxMenu:append(Menu, Id, Label),
    Menu.

append_menu(MenuBar, Menu, Title) ->
    wxMenuBar:append(MenuBar, Menu, Title),
    MenuBar.

set_menubar(Frame, MenuBar) ->
    wxFrame:setMenuBar(Frame, MenuBar),
    ok.

toolbar(Frame) ->
    wxFrame:createToolBar(Frame, [
        {style,
            ?wxTB_HORIZONTAL bor ?wxTB_FLAT bor ?wxTB_NODIVIDER}
    ]).

tool(ToolBar, Id, Label) ->
    wxToolBar:addTool(ToolBar, Id, Label, wxBitmap:new({16, 16})),
    ToolBar.

%% Toolbar tools with pictograms for Run/Stop: a green run triangle and a
%% red stop square, drawn with wxDC primitives (no binary assets).
tool(ToolBar, Id, Label, <<"run">>) ->
    wxToolBar:addTool(ToolBar, Id, Label, widget_icon(<<"run">>)),
    ToolBar;
tool(ToolBar, Id, Label, <<"stop">>) ->
    wxToolBar:addTool(ToolBar, Id, Label, widget_icon(<<"stop">>)),
    ToolBar;
tool(ToolBar, Id, Label, _Icon) ->
    tool(ToolBar, Id, Label).

%% The widget palette: pictogram tools inside the toolbar, to the right of
%% the Run/Stop tools (this wxErlang build's wxToolBar:addControl rejects
%% wxPanel, so a hosted panel would never appear). Presses are registered by
%% wx id so they reach the IDE as regular palette events.
palette(Bar, Entries) ->
    lists:foreach(
        fun({Kind, Label}) ->
            WxId = palette_next_id(),
            wxToolBar:addTool(Bar, WxId, <<>>, widget_icon(Kind)),
            catch wxToolBar:setToolShortHelp(Bar, WxId, Label),
            put(campy_palette_ids,
                maps:put(WxId, Kind, palette_ids_map()))
        end,
        Entries
    ),
    ok.

palette_ids_map() ->
    case get(campy_palette_ids) of
        undefined -> #{};
        M -> M
    end.

palette_owner(WxId) ->
    case maps:find(WxId, palette_ids_map()) of
        {ok, Kind} -> {ok, Kind};
        error -> {error, nil}
    end.

palette_next_id() ->
    Current = case get(campy_palette_next) of
        undefined -> 500000;
        N -> N
    end,
    put(campy_palette_next, Current + 1),
    Current.

%% ---------------------------------------------------------------------------
%% Pictograms: small 18x18 bitmaps drawn with wxDC primitives, one per widget
%% kind (and for the Run/Stop tools).
%% ---------------------------------------------------------------------------

widget_icon(Kind) ->
    Bmp = wxBitmap:new(18, 18),
    DC = wxMemoryDC:new(),
    wxMemoryDC:selectObject(DC, Bmp),
    wxDC:setBackground(DC, wxBrush:new({238, 239, 242})),
    wxDC:clear(DC),
    wxDC:setPen(DC, wxPen:new({62, 66, 74}, [{width, 1}])),
    draw_icon(DC, binary_to_atom(Kind, utf8)),
    wxMemoryDC:destroy(DC),
    Bmp.

draw_icon(DC, button) ->
    wxDC:setBrush(DC, wxBrush:new({168, 200, 240})),
    wxDC:drawRoundedRectangle(DC, {2, 5, 14, 8}, 2);
draw_icon(DC, label) ->
    wxDC:drawText(DC, <<"Ab">>, {3, 2});
draw_icon(DC, text) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 5, 14, 8}),
    wxDC:drawLine(DC, {4, 9}, {8, 9}),
    wxDC:drawLine(DC, {12, 6}, {12, 12});
draw_icon(DC, memo) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 3, 14, 12}),
    lists:foreach(fun(Y) -> wxDC:drawLine(DC, {4, Y}, {14, Y}) end,
                  [5, 8, 11]);
draw_icon(DC, checkbox) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {3, 5, 8, 8}),
    wxDC:setPen(DC, wxPen:new({20, 120, 60}, [{width, 2}])),
    wxDC:drawLine(DC, {4, 9}, {7, 12}),
    wxDC:drawLine(DC, {7, 12}, {12, 4}),
    wxDC:setPen(DC, wxPen:new({62, 66, 74}, [{width, 1}]));
draw_icon(DC, radio) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawCircle(DC, {8, 9}, 5),
    wxDC:setBrush(DC, wxBrush:new({20, 120, 60})),
    wxDC:drawCircle(DC, {8, 9}, 2);
draw_icon(DC, choice) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 5, 14, 8}),
    wxDC:drawLine(DC, {12, 8}, {14, 10}),
    wxDC:drawLine(DC, {14, 10}, {16, 8}),
    wxDC:drawLine(DC, {12, 8}, {16, 8});
draw_icon(DC, list) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 3, 14, 12}),
    lists:foreach(fun(Y) -> wxDC:drawLine(DC, {4, Y}, {14, Y}) end, [5, 9]);
draw_icon(DC, slider) ->
    wxDC:setPen(DC, wxPen:new({62, 66, 74}, [{width, 2}])),
    wxDC:drawLine(DC, {2, 9}, {16, 9}),
    wxDC:setPen(DC, wxPen:new({62, 66, 74}, [{width, 1}])),
    wxDC:setBrush(DC, wxBrush:new({168, 200, 240})),
    wxDC:drawCircle(DC, {11, 9}, 3);
draw_icon(DC, progress) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 6, 14, 6}),
    wxDC:setBrush(DC, wxBrush:new({40, 160, 90})),
    wxDC:drawRectangle(DC, {3, 7, 8, 4});
draw_icon(DC, picture) ->
    wxDC:setBrush(DC, wxBrush:new({250, 214, 110})),
    wxDC:drawCircle(DC, {12, 6}, 2),
    wxDC:setBrush(DC, wxBrush:new({120, 170, 110})),
    wxDC:drawPolygon(DC, [{3, 13}, {7, 7}, {10, 11}, {12, 9}, {15, 13}]);
draw_icon(DC, panel) ->
    wxDC:setBrush(DC, wxBrush:new({216, 220, 228})),
    wxDC:drawRectangle(DC, {2, 3, 14, 12});
draw_icon(DC, group) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 5, 14, 10}),
    wxDC:setBrush(DC, wxBrush:new({216, 220, 228})),
    wxDC:drawRectangle(DC, {2, 3, 7, 4});
draw_icon(DC, tree) ->
    wxDC:drawLine(DC, {3, 5}, {15, 5}),
    wxDC:drawLine(DC, {6, 5}, {6, 10}),
    wxDC:drawLine(DC, {12, 5}, {12, 10}),
    wxDC:drawLine(DC, {3, 10}, {9, 10}),
    wxDC:drawLine(DC, {3, 14}, {15, 14});
draw_icon(DC, grid) ->
    wxDC:drawRectangle(DC, {2, 3, 14, 12}),
    lists:foreach(fun(X) -> wxDC:drawLine(DC, {X, 3}, {X, 15}) end, [7, 12]),
    lists:foreach(fun(Y) -> wxDC:drawLine(DC, {2, Y}, {16, Y}) end, [7, 11]);
draw_icon(DC, editor) ->
    wxDC:setBrush(DC, wxBrush:new({255, 255, 255})),
    wxDC:drawRectangle(DC, {2, 3, 14, 12}),
    wxDC:setPen(DC, wxPen:new({150, 60, 140}, [{width, 2}])),
    wxDC:drawLine(DC, {4, 6}, {9, 6}),
    wxDC:setPen(DC, wxPen:new({30, 110, 160}, [{width, 2}])),
    wxDC:drawLine(DC, {4, 10}, {12, 10}),
    wxDC:setPen(DC, wxPen:new({62, 66, 74}, [{width, 1}]));
draw_icon(DC, run) ->
    wxDC:setPen(DC, wxPen:new({30, 130, 70})),
    wxDC:setBrush(DC, wxBrush:new({40, 170, 90})),
    wxDC:drawPolygon(DC, [{5, 3}, {14, 9}, {5, 15}]);
draw_icon(DC, stop) ->
    wxDC:setPen(DC, wxPen:new({150, 40, 40})),
    wxDC:setBrush(DC, wxBrush:new({190, 50, 50})),
    wxDC:drawRectangle(DC, {4, 4, 10, 10});
draw_icon(_DC, _Other) ->
    ok.

tool_separator(ToolBar) ->
    wxToolBar:addSeparator(ToolBar),
    ToolBar.

realize_toolbar(ToolBar) ->
    wxToolBar:realize(ToolBar),
    ok.

statusbar(Frame) ->
    wxFrame:createStatusBar(Frame).

set_status(StatusBar, Text) ->
    wxStatusBar:setStatusText(StatusBar, Text),
    ok.

notebook(Parent, Id) ->
    wxNotebook:new(Parent, Id, []).

page(Notebook, Id, Title) ->
    Panel = wxPanel:new(Notebook, [{winid, Id}]),
    wxNotebook:addPage(Notebook, Panel, Title),
    Panel.

notebook_selection(Notebook) ->
    wxNotebook:getSelection(Notebook).

select_page(Notebook, Index) ->
    wxNotebook:setSelection(Notebook, Index),
    ok.

tree(Parent, Id) ->
    wxTreeCtrl:new(Parent, [{id, Id}, {style, ?wxTR_HAS_BUTTONS bor ?wxTR_HIDE_ROOT}]).

tree_set(Tree, Items) ->
    wxTreeCtrl:deleteAllItems(Tree),
    Root = wxTreeCtrl:addRoot(Tree, <<"">>),
    add_tree_items(Tree, Root, Items),
    wxTreeCtrl:expand(Tree, Root),
    ok.

add_tree_items(_Tree, _Parent, []) ->
    ok;
add_tree_items(Tree, Parent, [{tree_item, Key, Label, Children} | Rest]) ->
    Item = wxTreeCtrl:appendItem(Tree, Parent, Label),
    wxTreeCtrl:setItemData(Tree, Item, Key),
    add_tree_items(Tree, Item, Children),
    add_tree_items(Tree, Parent, Rest).

tree_selected_key(Tree) ->
    try
        Item = wxTreeCtrl:getSelection(Tree),
        case wxTreeCtrl:getItemData(Tree, Item) of
            Key when is_binary(Key) -> Key;
            _ -> <<>>
        end
    catch
        _:_ -> <<>>
    end.

grid(Parent, Id) ->
    wxGrid:new(Parent, Id, []).

%% A property grid, not a data sheet: hide wx's row numbers and column letters,
%% use compact rows, turn off grid lines, and give the label column a fixed
%% width while the value column fills the remaining client area.
grid_configure(Grid, ShowLabels, ShowLines, RowHeight, LabelWidth) ->
    LabelSize =
        case ShowLabels of
            true -> 20;
            false -> 0
        end,
    catch wxGrid:setColLabelSize(Grid, LabelSize),
    catch wxGrid:setRowLabelSize(Grid, LabelSize),
    catch wxGrid:setDefaultRowSize(Grid, RowHeight, [{resizeExistingRows, true}]),
    catch wxGrid:enableGridLines(Grid, ShowLines),
    catch wxGrid:setColMinimalWidth(Grid, 0, 40),
    catch wxGrid:setColSize(Grid, 0, LabelWidth),
    catch wxGrid:setColSize(Grid, 1, max(80, LabelWidth)),
    put(campy_grid_label_widths,
        maps:put(Grid, LabelWidth, grid_label_widths_map())),
    ok.

grid_label_widths_map() ->
    case get(campy_grid_label_widths) of
        undefined -> #{};
        M -> M
    end.

grid_label_width(Grid) ->
    case maps:find(Grid, grid_label_widths_map()) of
        {ok, Width} when is_integer(Width) -> Width;
        _ -> 110
    end.

grid_fit_value_column(Grid, LabelWidth) ->
    try
        {Width, _Height} = wxWindow:getClientSize(Grid),
        ValueWidth = Width - LabelWidth - 8,
        case ValueWidth > 80 of
            true -> wxGrid:setColSize(Grid, 1, ValueWidth);
            false -> ok
        end
    catch
        _:_ -> ok
    end,
    ok.

grid_set(Grid, Rows) ->
    %% A fresh row set invalidates the remembered enum cells.
    put(campy_enum_cells, maps:remove(Grid, enum_cells_map())),
    RowCount = length(Rows),
    ColCount = case Rows of
        [] -> 0;
        [First | _] -> length(First)
    end,
    case ColCount of
        0 -> ok;
        _ ->
            adjust_grid(Grid, RowCount, ColCount),
            catch wxGrid:setDefaultRowSize(Grid, 22, [{resizeExistingRows, true}]),
            wxGrid:beginBatch(Grid),
            set_grid_rows(Grid, Rows, 0),
            wxGrid:endBatch(Grid),
            grid_fit_value_column(Grid, grid_label_width(Grid))
    end,
    ok.

adjust_grid(Grid, RowCount, ColCount) ->
    case {wxGrid:getNumberRows(Grid), wxGrid:getNumberCols(Grid)} of
        {0, 0} ->
            wxGrid:createGrid(Grid, RowCount, ColCount),
            catch wxGrid:enableEditing(Grid, true),
            %% Field/value rows: no A/B column letters or 1/2 row numbers.
            catch wxGrid:setColLabelSize(Grid, 0),
            catch wxGrid:setRowLabelSize(Grid, 0),
            catch wxGrid:enableGridLines(Grid, false),
            catch wxGrid:setColSize(Grid, 0, 110),
            catch wxGrid:setColSize(Grid, 1, 180);
        {OldRows, OldCols} ->
            if
                RowCount > OldRows ->
                    wxGrid:appendRows(Grid, [{numRows, RowCount - OldRows}]);
                RowCount < OldRows ->
                    wxGrid:deleteRows(Grid, [{pos, 0}, {numRows, OldRows - RowCount}]);
                true -> ok
            end,
            if
                ColCount > OldCols ->
                    wxGrid:appendCols(Grid, [{numCols, ColCount - OldCols}]);
                ColCount < OldCols ->
                    wxGrid:deleteCols(Grid, [{pos, 0}, {numCols, OldCols - ColCount}]);
                true -> ok
            end
    end.

set_grid_rows(_Grid, [], _Row) ->
    ok;
set_grid_rows(Grid, [Values | Rest], Row) ->
    set_grid_cells(Grid, Values, Row, 0),
    set_grid_rows(Grid, Rest, Row + 1).

set_grid_cells(_Grid, [], _Row, _Col) ->
    ok;
set_grid_cells(Grid, [Value | Rest], Row, Col) ->
    wxGrid:setCellValue(Grid, Row, Col, Value),
    set_grid_cells(Grid, Rest, Row, Col + 1).

grid_cell(Grid) ->
    Row = wxGrid:getGridCursorRow(Grid),
    Col = wxGrid:getGridCursorCol(Grid),
    Text = unicode:characters_to_binary(wxGrid:getCellValue(Grid, Row, Col)),
    {grid_cell, Row, Col, Text}.

%% Inspector cells are typed: geometry gets the integer editor, everything else
%% stays a text editor. The grid takes ownership of each editor it is given.
grid_number_cell(Grid, Row, Col, Min) ->
    %% wx's number editor creates a GTK spin button with min/max; supplying
    %% only one leaves the other at 0/-1 and GTK aborts the editor on open.
    Editor = wxGridCellNumberEditor:new([{min, Min}, {max, 1000000}]),
    wxGrid:setCellEditor(Grid, Row, Col, Editor),
    ok.

grid_text_cell(Grid, Row, Col) ->
    Editor = wxGridCellTextEditor:new(),
    wxGrid:setCellEditor(Grid, Row, Col, Editor),
    ok.

grid_read_only(Grid, Row, Col, ReadOnly) ->
    wxGrid:setReadOnly(Grid, Row, Col, [{isReadOnly, ReadOnly}]),
    ok.

%% A dropdown cell editor for enum properties (align, layout). The editor
%% commits through the same grid_cell_changed event as the text editors.
%% An enum property cell. The options are remembered; the dropdown popup
%% opens automatically as soon as the cell is selected (see next_message).
grid_choice_cell(Grid, Row, Col, Options) ->
    Cells = enum_cells_map(),
    PerGrid = case maps:find(Grid, Cells) of
        {ok, M} -> M;
        error -> #{}
    end,
    put(campy_enum_cells,
        maps:put(Grid, maps:put({Row, Col}, Options, PerGrid), Cells)),
    ok.

enum_cells_map() ->
    case get(campy_enum_cells) of
        undefined -> #{};
        M -> M
    end.

%% The enum dropdown: a transient popup list anchored under the selected
%% cell. It pops open immediately and commits through the grid event path.
maybe_enum_popup(Grid, Row, Col) ->
    case maps:find(Grid, enum_cells_map()) of
        {ok, Cells} ->
            case maps:find({Row, Col}, Cells) of
                {ok, Options} ->
                    enum_popup(Grid, Row, Col, Options),
                    idle;
                error ->
                    idle
            end;
        error ->
            idle
    end.

%% Anchored under the cell like a real dropdown: parented to the toplevel
%% (GTK refuses to position parentless popups) and placed just below the
%% cell, in the toplevel's client coordinates (move() is parent-relative).
enum_popup(Grid, Row, Col, Options) ->
    enum_popup_dismiss(),
    {CX, CY, CW, CH} = wxGrid:cellToRect(Grid, Row, Col),
    {SX, SY} = wxWindow:clientToScreen(Grid, {CX, CY}),
    Frame = toplevel(Grid),
    Popup = wxPopupTransientWindow:new(Frame, []),
    ListId = palette_next_id(),
    List = wxListBox:new(Popup, ListId, [{style, ?wxLB_SINGLE}]),
    lists:foreach(fun(Option) -> wxListBox:append(List, Option) end, Options),
    %% Preselect the cell's current value when it is one of the options.
    Current = unicode:characters_to_binary(
                wxGrid:getCellValue(Grid, Row, Col)),
    case lists:search(fun(O) -> O =:= Current end, Options) of
        {value, Value} ->
            wxListBox:select(List, list_index(Value, Options, 0));
        false ->
            ok
    end,
    wxListBox:connect(List, command_listbox_selected, []),
    Height = 6 + 22 * erlang:min(length(Options), 8),
    Width = erlang:max(CW, 120),
    wxWindow:setClientSize(Popup, Width, Height),
    %% The popup is an override-redirect GTK window, so move() takes SCREEN
    %% coordinates directly — not frame-relative ones. Drop it just below
    %% the cell; flip it above the cell and clamp it inside the display's
    %% client area when it would overflow the bottom edge.
    {DA, DB, DW, DH} = display_client_area(Frame),
    PY = case SY + CH + Height =< DB + DH of
             true -> SY + CH;
             false -> erlang:max(SY - Height, DB)
         end,
    PX = erlang:min(erlang:max(SX, DA), DA + DW - Width),
    wxWindow:move(Popup, {PX, PY}),
    wxPopupTransientWindow:popup(Popup),
    put(campy_enum_popup,
        {Popup, List, wxWindow:getId(Grid), Row, Col, SX, SY + CH}),
    ok.

%% The work area of the display the window is on.
display_client_area(Frame) ->
    Display = wxDisplay:new(Frame),
    try wxDisplay:getClientArea(Display)
        after wxDisplay:destroy(Display)
    end.

%% Walk up to the owning top-level window.
toplevel(Win) ->
    case wxWindow:isTopLevel(Win) of
        true -> Win;
        false -> toplevel(wxWindow:getParent(Win))
    end.

list_index(Value, [Value | _], Index) -> Index;
list_index(Value, [_ | Rest], Index) -> list_index(Value, Rest, Index + 1);
list_index(_Value, [], _Index) -> 0.

enum_popup_dismiss() ->
    case get(campy_enum_popup) of
        undefined ->
            ok;
        {Popup, _List, _GridId, _Row, _Col, _SX, _SY} ->
            catch wxPopupTransientWindow:dismiss(Popup),
            catch wxPopupTransientWindow:destroy(Popup),
            erase(campy_enum_popup),
            ok
    end.

%% The popup's chosen option reaches the IDE as the grid's own change event.
enum_popup_pick(ListId, _CmdInt) ->
    case get(campy_enum_popup) of
        undefined ->
            idle;
        {_Popup, List, GridId, Row, Col, _SX, _SY} ->
            case wxWindow:getId(List) =:= ListId of
                true ->
                    Label =
                        case catch unicode:characters_to_binary(
                                       wxControlWithItems:getStringSelection(
                                           List)) of
                            {'EXIT', _} -> <<>>;
                            Text when is_binary(Text) -> Text
                        end,
                    enum_popup_dismiss(),
                    {grid_event, GridId, Row, Col, Label};
                false ->
                    idle
            end
    end.

editor(Parent, Id) ->
    Editor = wxStyledTextCtrl:new(Parent, [{id, Id}]),
    wxStyledTextCtrl:styleSetFaceName(Editor, 0, <<"monospace">>),
    wxStyledTextCtrl:styleSetSize(Editor, 0, 11),
    wxStyledTextCtrl:styleClearAll(Editor),
    wxStyledTextCtrl:setMarginType(Editor, 0, ?wxSTC_MARGIN_NUMBER),
    wxStyledTextCtrl:setMarginWidth(Editor, 0, 40),
    Editor.

editor_set(Editor, Text, ReadOnly) ->
    %% SCI_SETTEXT is ignored while the control is read-only in this wx build,
    %% so clear the flag, replace the document, then restore it. Without this,
    %% refreshing a read-only pane (Generated source, console) silently no-ops.
    wxStyledTextCtrl:setReadOnly(Editor, false),
    wxStyledTextCtrl:setText(Editor, Text),
    wxStyledTextCtrl:setReadOnly(Editor, ReadOnly),
    %% A programmatic load is one giant undoable action: enough Ctrl+Z would
    %% wipe the loaded document to an empty buffer. Cut the stack after a
    %% load so undo only covers the user's own edits.
    catch wxStyledTextCtrl:emptyUndoBuffer(Editor),
    ok.

%% ---------------------------------------------------------------------------
%% Code editor: Gleam syntax highlighting, caret/position access, language
%% server diagnostics (squiggles + margin markers) and completion popups.
%% ---------------------------------------------------------------------------

%% Gleam highlighting on a Scintilla editor. wxErlang exposes no indicators
%% and no automatic Gleam lexer, so the editor uses the container lexer: the
%% styles below are defined once here, and `editor_style_gleam` tokenizes the
%% buffer eagerly (it is re-run after every document replacement). Diagnostics
%% underline whole lines by restyling them with one of the underline styles.
editor_gleam(Editor) ->
    wxStyledTextCtrl:setLexer(Editor, ?wxSTC_LEX_CONTAINER),
    wxStyledTextCtrl:setWrapMode(Editor, ?wxSTC_WRAP_NONE),
    wxStyledTextCtrl:setIndentationGuides(Editor, ?wxSTC_IV_LOOKBOTH),
    wxStyledTextCtrl:setTabWidth(Editor, 2),
    wxStyledTextCtrl:setUseTabs(Editor, false),
    %% 1 keyword (rose), 2 comment (grey-green italic), 3 string (teal),
    %% 4 number (blue), 5 operator (mid grey), 6 type-ish (brown).
    wxStyledTextCtrl:styleSetForeground(Editor, 1, {158, 33, 116}),
    wxStyledTextCtrl:styleSetForeground(Editor, 2, {104, 128, 104}),
    wxStyledTextCtrl:styleSetItalic(Editor, 2, true),
    wxStyledTextCtrl:styleSetForeground(Editor, 3, {22, 120, 108}),
    wxStyledTextCtrl:styleSetForeground(Editor, 4, {28, 96, 176}),
    wxStyledTextCtrl:styleSetForeground(Editor, 5, {90, 94, 104}),
    wxStyledTextCtrl:styleSetForeground(Editor, 6, {140, 76, 24}),
    %% Diagnostic underline styles: 21 error, 22 warning, 23 info.
    wxStyledTextCtrl:styleSetForeground(Editor, 21, {204, 26, 79}),
    wxStyledTextCtrl:styleSetUnderline(Editor, 21, true),
    wxStyledTextCtrl:styleSetForeground(Editor, 22, {216, 130, 4}),
    wxStyledTextCtrl:styleSetUnderline(Editor, 22, true),
    wxStyledTextCtrl:styleSetForeground(Editor, 23, {86, 124, 204}),
    wxStyledTextCtrl:styleSetUnderline(Editor, 23, true),
    %% Margin markers per severity (Scintilla marks: circle, arrow, dots).
    wxStyledTextCtrl:markerDefine(Editor, 0, ?wxSTC_MARK_CIRCLE),
    wxStyledTextCtrl:markerSetBackground(Editor, 0, {204, 26, 79}),
    wxStyledTextCtrl:markerDefine(Editor, 1, ?wxSTC_MARK_SHORTARROW),
    wxStyledTextCtrl:markerSetBackground(Editor, 1, {216, 130, 4}),
    wxStyledTextCtrl:markerDefine(Editor, 2, ?wxSTC_MARK_DOTDOTDOT),
    wxStyledTextCtrl:markerSetBackground(Editor, 2, {86, 124, 204}),
    ok.

%% Token-color the whole buffer. Runs after every document replacement (the
%% styling bytes live in the document, so a replacement resets them). The
%% text is passed in by the caller: reading it back through wx in the same
%% command batch as the preceding setText can return stale content, while
%% styling itself is a pure write and lands in order.
editor_style_gleam(Editor, Text) ->
    Runs = gleam_runs(Text),
    wxStyledTextCtrl:startStyling(Editor, 0),
    apply_runs(Editor, Runs).

apply_runs(_Editor, []) ->
    ok;
apply_runs(Editor, [{Length, Style} | Rest]) ->
    wxStyledTextCtrl:setStyling(Editor, Length, Style),
    apply_runs(Editor, Rest).

%% ---------------------------------------------------------------------------
%% A small Gleam tokenizer over the raw UTF-8 document. Positions in Scintilla
%% are byte offsets, so runs are counted in bytes. Tokens per line:
%% // comments, "strings", keywords, numbers, UpperCase identifiers (types and
%% record constructors), operators. Multi-byte characters count as word parts.
%% ---------------------------------------------------------------------------

-define(GLEAM_KEYWORDS,
    [<<"alias">>, <<"as">>, <<"assert">>, <<"case">>, <<"const">>, <<"echo">>,
     <<"external">>, <<"fn">>, <<"if">>, <<"import">>, <<"implement">>,
     <<"let">>, <<"opaque">>, <<"panic">>, <<"pub">>, <<"todo">>, <<"type">>,
     <<"use">>, <<"True">>, <<"False">>, <<"Nil">>]).

gleam_runs(Bin) ->
    lists:flatten(gleam_lines(Bin, [])).

gleam_lines(<<>>, Acc) ->
    lists:reverse(Acc);
gleam_lines(Bin, Acc) ->
    case binary:split(Bin, <<"\n">>) of
        [Line, Rest] ->
            gleam_lines(Rest, [line_runs(Line) ++ [{1, 0}] | Acc]);
        [Line] ->
            %% The final chunk has no trailing newline.
            gleam_lines(<<>>, [line_runs(Line) | Acc])
    end.

line_runs(Line) ->
    lists:reverse(line_scan(Line, [])).

line_scan(<<>>, Acc) ->
    Acc;
line_scan(<<"//", _/binary>> = Bin, Acc) ->
    [{byte_size(Bin), 2} | Acc];
line_scan(<<"\"", Rest/binary>>, Acc) ->
    {Length, Rest2} = string_span(Rest),
    line_scan(Rest2, [{Length + 1, 3} | Acc]);
line_scan(Bin, Acc) ->
    case word_len(Bin) of
        {Length, Rest} when Length > 0 ->
            Word = binary_part(Bin, 0, Length),
            line_scan(Rest, [{Length, word_style(Word)} | Acc]);
        _ ->
            <<Char, Rest/binary>> = Bin,
            Style = case Char of
                C when C =:= $\s; C =:= $\t -> 0;
                _ -> 5
            end,
            line_scan(Rest, [{1, Style} | Acc])
    end.

word_style(Word) ->
    case lists:member(Word, ?GLEAM_KEYWORDS) of
        true -> 1;
        false ->
            <<First, _/binary>> = Word,
            case First of
                C when C >= $0, C =< $9 -> 4;
                C when C >= $A, C =< $Z -> 6;
                _ -> 0
            end
    end.

%% Word characters: ASCII letters, digits, underscore, and anything multi-byte.
word_len(Bin) ->
    word_len(Bin, 0, Bin).

word_len(<<Char, Rest/binary>>, N, Whole) when
        (Char >= $a andalso Char =< $z);
        (Char >= $A andalso Char =< $Z);
        (Char >= $0 andalso Char =< $9);
        Char =:= $_;
        Char >= 16#80 ->
    word_len(Rest, N + 1, Whole);
word_len(_Rest, N, Whole) ->
    {N, binary_part(Whole, N, byte_size(Whole) - N)}.

string_span(Bin) ->
    string_span(Bin, 0).

string_span(<<>>, N) ->
    {N, <<>>};
string_span(<<"\"", Rest/binary>>, N) ->
    {N + 1, Rest};
string_span(<<"\\", _Escaped, Rest/binary>>, N) ->
    string_span(Rest, N + 2);
string_span(<<_, Rest/binary>>, N) ->
    string_span(Rest, N + 1).

%% The word under the caret: its start and end offsets plus the text, or
%% {error, none} when the caret is not on a word.
editor_word_at(Editor) ->
    Pos = wxStyledTextCtrl:getCurrentPos(Editor),
    Start = wxStyledTextCtrl:wordStartPosition(Editor, Pos, true),
    End = wxStyledTextCtrl:wordEndPosition(Editor, Pos, true),
    case End > Start of
        true ->
            Text = unicode:characters_to_binary(
                     wxStyledTextCtrl:getTextRange(Editor, Start, End)),
            {ok, {Start, End, Text}};
        false ->
            {error, none}
    end.

%% Replace the text of a 0-based line (used by the LSP formatter).
editor_replace_line(Editor, Line, NewText) ->
    LineStart = wxStyledTextCtrl:positionFromLine(Editor, Line),
    LineEnd = wxStyledTextCtrl:getLineEndPosition(Editor, Line),
    wxStyledTextCtrl:setTargetStart(Editor, LineStart),
    wxStyledTextCtrl:setTargetEnd(Editor, LineEnd),
    wxStyledTextCtrl:replaceTarget(Editor, NewText),
    ok.

%% Show the end of a freshly rewritten source file, so an appended ABI stub is
%% visible immediately after the event click opens the Code page.
%% Jump-to-symbol list: Scintilla's autocomp popup with "name:line" entries.
%% The selection arrives as an stc_autocomp_selection event (connected here);
%% editor_jumped/1 reads the picked text.
editor_jump_list(Editor, Entries) ->
    wxStyledTextCtrl:connect(Editor, stc_autocomp_selection, []),
    put(campy_jump_entries, {Editor, Entries}),
    %% Jump entries are "name:line"; they never contain spaces, so the list can
    %% be joined with spaces once the separator is a space (autocomplete sets
    %% the separator to \n globally).
    wxStyledTextCtrl:autoCompSetSeparator(Editor, $\s),
    Spaced = lists:join(<<" ">>, Entries),
    Options = unicode:characters_to_binary(erlang:iolist_to_binary(Spaced)),
    wxStyledTextCtrl:autoCompShow(Editor, 0, Options),
    ok.

%% The picked entry, by the completion popup's current selection. wxErlang has
%% no autoCompGetCurrentText, so the entry list is read from the process
%% dictionary copy written by editor_jump_list/2.
editor_jumped(Editor) ->
    Index = case catch wxStyledTextCtrl:autoCompGetCurrent(Editor) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end,
    {ok, jump_entry(Editor, Index)}.

jump_entry(Editor, Index) ->
    case get(campy_jump_entries) of
        {Editor, Entries} when is_list(Entries) ->
            case Entries of
                [] -> <<>>;
                _ ->
                    N = Index + 1,
                    case N >= 1 andalso N =< length(Entries) of
                        true -> lists:nth(N, Entries);
                        false -> hd(Entries)
                    end
            end;
        _ ->
            <<>>
    end.

%% Jump entries may belong to a different editor; fall back to whatever was
%% stored last so a pick never goes missing.
jump_entry_any(Index) ->
    case get(campy_jump_entries) of
        {_Editor, Entries} when is_list(Entries) ->
            case Entries of
                [] -> <<>>;
                _ ->
                    N = Index + 1,
                    case N >= 1 andalso N =< length(Entries) of
                        true -> lists:nth(N, Entries);
                        false -> hd(Entries)
                    end
            end;
        _ ->
            <<>>
    end.

%% The text of the picked jump entry: the event carries it; if wx left it
%% empty, ask the popup for its current index and read the stored entry;
%% finally treat the event position as a (possibly stale) index.
jump_pick(Editor, Event) ->
    case jump_event_text(Event) of
        <<>> ->
            Index = case catch wxStyledTextCtrl:autoCompGetCurrent(Editor) of
                N when is_integer(N), N >= 0 -> N;
                _ -> jump_event_position(Event)
            end,
            case jump_entry_any(Index) of
                <<>> -> jump_entry_any(0);
                Text -> Text
            end;
        Text ->
            Text
    end.

jump_event_text(Event) ->
    try
        case element(7, Event) of
            Value when is_binary(Value) -> unicode:characters_to_binary(Value);
            Value when is_list(Value) -> unicode:characters_to_binary(Value);
            _ -> <<>>
        end
    catch
        _:_ -> <<>>
    end.

jump_event_position(Event) ->
    try
        case element(3, Event) of
            N when is_integer(N), N >= 0 -> N;
            _ -> 0
        end
    catch
        _:_ -> 0
    end.

%% (The selection event is connected by editor_jump_list/2; kept for clarity.)
editor_connect_jump(_Editor) ->
    ok.

%% wxTextCtrl:getValue does not work on wxStyledTextCtrl; read the buffer
%% directly.
editor_get_text(Editor) ->
    unicode:characters_to_binary(wxStyledTextCtrl:getText(Editor)).

%% Explicit clipboard/undo commands on a Scintilla editor: this GTK build
%% drops the default key bindings when a frame accelerator table is
%% installed, so the IDE applies them on the key event instead.
editor_clipboard(Editor, Action) ->
    case Action of
        <<"copy">> -> wxStyledTextCtrl:copy(Editor);
        <<"cut">> -> wxStyledTextCtrl:cut(Editor);
        <<"paste">> -> wxStyledTextCtrl:paste(Editor);
        <<"undo">> -> wxStyledTextCtrl:undo(Editor);
        <<"redo">> -> wxStyledTextCtrl:redo(Editor);
        _ -> ok
    end.

%% The caret as a 0-based {Line, Column} pair, the shape the language server
%% client expects.
editor_caret(Editor) ->
    Pos = wxStyledTextCtrl:getCurrentPos(Editor),
    Line = wxStyledTextCtrl:lineFromPosition(Editor, Pos),
    Col = Pos - wxStyledTextCtrl:positionFromLine(Editor, Line),
    {caret, Line, Col}.

editor_goto(Editor, Line, Col) ->
    Start = wxStyledTextCtrl:positionFromLine(Editor, Line),
    wxStyledTextCtrl:gotoPos(Editor, Start + Col),
    wxStyledTextCtrl:ensureCaretVisible(Editor),
    ok.

%% Paint language-server diagnostics: restyle the offending lines with an
%% underline style (error/warning/info) and add a margin marker. wxErlang has
%% no indicator API, so the underline is carried by styles 21/22/23 and the
%% marker by the margin. Rows are {StartLine, EndLine, Message, Severity}
%% with 0-based lines.
editor_diagnostics(Editor, Rows) ->
    %% Drop the markers left by the previous run before adding this set;
    %% otherwise stale findings accumulate in the margin.
    lists:foreach(
        fun(Handle) -> catch wxStyledTextCtrl:markerDeleteAll(Editor, Handle) end,
        [0, 1, 2]
    ),
    underline_diagnostics(Editor, Rows).

underline_diagnostics(_Editor, []) ->
    ok;
underline_diagnostics(Editor, [{Line, _EndLine, _Text, Severity} | Rest]) ->
    {Style, Marker} = case Severity of
        1 -> {21, 0};
        2 -> {22, 1};
        _ -> {23, 2}
    end,
    Start = wxStyledTextCtrl:positionFromLine(Editor, Line),
    End = wxStyledTextCtrl:getLineEndPosition(Editor, Line),
    case Start =:= -1 orelse End =:= -1 orelse End =< Start of
        false ->
            wxStyledTextCtrl:startStyling(Editor, Start),
            wxStyledTextCtrl:setStyling(Editor, End - Start, Style),
            catch wxStyledTextCtrl:markerAdd(Editor, Line, Marker),
            ok;
        true ->
            ok
    end,
    underline_diagnostics(Editor, Rest).

%% Show the completion popup, replacing the word prefix under the caret.
%% autoCompShow's first argument is how many characters of the word are
%% already typed; the popup then covers them, so choosing an item replaces
%% the partial word. Labels are joined with \n (separator 10) so labels
%% containing spaces or punctuation stay whole.
editor_autocomplete(_Editor, []) ->
    ok;
editor_autocomplete(Editor, Labels) ->
    Pos = wxStyledTextCtrl:getCurrentPos(Editor),
    Start = wxStyledTextCtrl:wordStartPosition(Editor, Pos, true),
    wxStyledTextCtrl:autoCompSetSeparator(Editor, $\n),
    wxStyledTextCtrl:autoCompSetCancelAtStart(Editor, false),
    wxStyledTextCtrl:autoCompShow(Editor, Pos - Start, join_labels(Labels)),
    ok.

join_labels([Label]) ->
    Label;
join_labels([Label | Rest]) ->
    <<Label/binary, 10, (join_labels(Rest))/binary>>.

%% wxTextCtrl:getValue does not work on wxStyledTextCtrl; read the buffer
%% directly.
%% Debug: the wx object id inside a ref.
editor_show_end(Editor) ->
    Pos = wxStyledTextCtrl:getTextLength(Editor),
    wxStyledTextCtrl:gotoPos(Editor, Pos),
    wxStyledTextCtrl:ensureCaretVisible(Editor),
    ok.

open_dialog(Frame, Wildcard) ->
    Dialog = wxFileDialog:new(Frame, [
        {wildcard, Wildcard},
        {style, ?wxFD_OPEN bor ?wxFD_FILE_MUST_EXIST}
    ]),
    Result = case wxFileDialog:showModal(Dialog) of
        ?wxID_OK -> unicode:characters_to_binary(wxFileDialog:getPath(Dialog));
        _ -> <<>>
    end,
    wxFileDialog:destroy(Dialog),
    Result.

save_dialog(Frame, Wildcard, Default) ->
    Dialog = wxFileDialog:new(Frame, [
        {wildcard, Wildcard},
        {defaultFile, Default},
        {style, ?wxFD_SAVE bor ?wxFD_OVERWRITE_PROMPT}
    ]),
    Result = case wxFileDialog:showModal(Dialog) of
        ?wxID_OK -> unicode:characters_to_binary(wxFileDialog:getPath(Dialog));
        _ -> <<>>
    end,
    wxFileDialog:destroy(Dialog),
    Result.

show_message(Frame, Title, Message) ->
    Dialog = wxMessageDialog:new(Frame, Message, [{caption, Title}]),
    _ = wxMessageDialog:showModal(Dialog),
    wxMessageDialog:destroy(Dialog),
    ok.

%% ---------------------------------------------------------------------------
%% Settings dialogs (Settings → Editor…, Settings → Agent…). Each builds a
%% small modal dialog, blocks in showModal, and returns the accepted values or
%% {error, nil} on Cancel. Indexes address the caller's option lists, so the
%% shell never has to trust the dialog's text.
%% ---------------------------------------------------------------------------

settings_dialog(Frame, Fonts, Sizes, Schemes, FontIdx, SizeIdx, SchemeIdx) ->
    Dialog = wxDialog:new(Frame, ?wxID_ANY, <<"Editor settings">>, []),
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    FontChoice = add_choice(Dialog, Sizer, <<"Font">>, Fonts, FontIdx),
    SizeChoice = add_choice(Dialog, Sizer, <<"Font size">>, Sizes, SizeIdx),
    SchemeChoice = add_choice(Dialog, Sizer, <<"Color scheme">>, Schemes, SchemeIdx),
    Buttons = wxDialog:createStdDialogButtonSizer(Dialog, ?wxOK bor ?wxCANCEL),
    wxSizer:add(Sizer, Buttons, [{flag, ?wxALL bor ?wxALIGN_CENTRE}, {border, 8}]),
    wxWindow:setSizerAndFit(Dialog, Sizer),
    Answer = wxDialog:showModal(Dialog),
    Result = case Answer =:= ?wxID_OK of
        true ->
            {ok, {wxChoice:getSelection(FontChoice),
                  wxChoice:getSelection(SizeChoice),
                  wxChoice:getSelection(SchemeChoice)}};
        false -> {error, nil}
    end,
    wxDialog:destroy(Dialog),
    Result.

agent_dialog(Frame, Enabled, Port, Status, Endpoint) ->
    Dialog = wxDialog:new(Frame, ?wxID_ANY, <<"Agent settings">>, []),
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    Check = wxCheckBox:new(Dialog, ?wxID_ANY, <<"Enable MCP server">>, []),
    wxCheckBox:setValue(Check, Enabled),
    wxSizer:add(Sizer, Check, [{flag, ?wxALL}, {border, 8}]),
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Row, wxStaticText:new(Dialog, ?wxID_ANY, <<"Port">>, []),
                [{flag, ?wxALL bor ?wxALIGN_CENTRE_VERTICAL}, {border, 8}]),
    PortText = wxTextCtrl:new(Dialog, ?wxID_ANY, [{value, Port}]),
    wxSizer:add(Row, PortText, [{proportion, 1}, {flag, ?wxALL}, {border, 8}]),
    wxSizer:add(Sizer, Row, [{flag, ?wxEXPAND}]),
    wxSizer:add(Sizer, wxStaticText:new(Dialog, ?wxID_ANY, Status, []),
                [{flag, ?wxLEFT bor ?wxRIGHT}, {border, 8}]),
    wxSizer:add(Sizer, wxStaticText:new(Dialog, ?wxID_ANY, Endpoint, []),
                [{flag, ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM}, {border, 8}]),
    Buttons = wxDialog:createStdDialogButtonSizer(Dialog, ?wxOK bor ?wxCANCEL),
    wxSizer:add(Sizer, Buttons, [{flag, ?wxALL bor ?wxALIGN_CENTRE}, {border, 8}]),
    wxWindow:setSizerAndFit(Dialog, Sizer),
    Answer = wxDialog:showModal(Dialog),
    Result = case Answer =:= ?wxID_OK of
        true ->
            {ok, {wxCheckBox:getValue(Check),
                  unicode:characters_to_binary(wxTextCtrl:getValue(PortText))}};
        false -> {error, nil}
    end,
    wxDialog:destroy(Dialog),
    Result.

%% One labelled combo row inside a settings dialog.
add_choice(Dialog, Sizer, Label, Items, Selected) ->
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Row, wxStaticText:new(Dialog, ?wxID_ANY, Label, []),
                [{flag, ?wxALL bor ?wxALIGN_CENTRE_VERTICAL}, {border, 8}]),
    Choice = wxChoice:new(Dialog, ?wxID_ANY, []),
    lists:foreach(fun(Item) -> wxChoice:append(Choice, Item) end, Items),
    wxChoice:setSelection(Choice, Selected),
    wxSizer:add(Row, Choice, [{proportion, 1}, {flag, ?wxALL}, {border, 8}]),
    wxSizer:add(Sizer, Row, [{flag, ?wxEXPAND}]),
    Choice.

%% Recolor an editor's Scintilla styles from a scheme palette (Gleam sends
%% [{Key, <<"#rrggbb">>}]). "bg"/"fg" are the default style's background and
%% foreground; the rest map onto the token styles editor_gleam defines.
editor_scheme(Editor, Palette) ->
    lists:foreach(fun({Key, Hex}) -> apply_scheme(Editor, Key, Hex) end, Palette),
    wxStyledTextCtrl:refresh(Editor, []),
    ok.

apply_scheme(Editor, <<"bg">>, Hex) ->
    wxStyledTextCtrl:styleSetBackground(Editor, 0, hex_rgb(Hex, {28, 28, 28}));
apply_scheme(Editor, <<"fg">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 0, hex_rgb(Hex, {200, 200, 200}));
apply_scheme(Editor, <<"keyword">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 1, hex_rgb(Hex, {158, 33, 116}));
apply_scheme(Editor, <<"comment">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 2, hex_rgb(Hex, {104, 128, 104}));
apply_scheme(Editor, <<"string">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 3, hex_rgb(Hex, {22, 120, 108}));
apply_scheme(Editor, <<"number">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 4, hex_rgb(Hex, {28, 96, 176}));
apply_scheme(Editor, <<"punct">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 5, hex_rgb(Hex, {90, 94, 104}));
apply_scheme(Editor, <<"type">>, Hex) ->
    wxStyledTextCtrl:styleSetForeground(Editor, 6, hex_rgb(Hex, {140, 76, 24}));
apply_scheme(_Editor, _Key, _Hex) ->
    ok.

%% Apply the chosen editor font (Settings → Editor…) to every style the
%% editors use, so tokens and diagnostics keep the family and size.
editor_font(Editor, Face, Size) ->
    lists:foreach(fun(Style) ->
        wxStyledTextCtrl:styleSetFaceName(Editor, Style, Face),
        wxStyledTextCtrl:styleSetSize(Editor, Style, Size)
    end, [0, 1, 2, 3, 4, 5, 6, 21, 22, 23]),
    wxStyledTextCtrl:refresh(Editor, []),
    ok.

%% Parse "#rrggbb" (with or without '#', case-insensitive) into an RGB tuple;
%% anything unparsable falls back to Default.
hex_rgb(Hex, Default) ->
    try
        Digits = case Hex of
            <<_, Rest/binary>> -> Rest;
            _ -> Hex
        end,
        <<R:2/binary, G:2/binary, B:2/binary>> = Digits,
        {binary_to_integer(R, 16), binary_to_integer(G, 16),
         binary_to_integer(B, 16)}
    catch
        _:_ -> Default
    end.

%% Designer canvas

canvas(Parent, Id) ->
    Panel = wxPanel:new(Parent, [{winid, Id}, {style, ?wxFULL_REPAINT_ON_RESIZE}]),
    wxPanel:setBackgroundColour(Panel, {245, 246, 248}),
    %% The form plate is pre-created as the canvas's FIRST child: GTK stacks
    %% children by creation order (Raise/Lower are no-ops for children on
    %% this build), so design controls created after it always paint above
    %% the plate. It stays hidden at 1x1 until form_plate_set positions it.
    PlateId = grab_next_id(),
    Plate = wxPanel:new(Panel,
                        [{winid, PlateId},
                         {style, ?wxBORDER_SIMPLE bor ?wxFULL_REPAINT_ON_RESIZE}]),
    wxPanel:setBackgroundColour(Plate, {255, 255, 255}),
    wxWindow:move(Plate, {0, 0}),
    wxWindow:setSize(Plate, {1, 1}),
    %% Shown NOW, never hidden again: GTK3 stacks siblings by show order,
    %% and a plate shown later than the controls would cover them. It stays
    %% visually inert at 1x1 until form_plate_set positions it.
    wxWindow:show(Plate),
    wxPanel:connect(Plate, left_down, []),
    wxPanel:connect(Plate, motion, []),
    wxPanel:connect(Plate, left_up, []),
    put(campy_canvas_plates,
        maps:put(Panel, {Plate, PlateId, undefined}, canvas_plate_map())),
    %% Canvas painting is SYNCHRONOUS: a wxPaintDC must be created while the
    %% GTK expose dispatch is still active. Events delivered to the owner's
    %% mailbox arrive too late and draw nothing, so the paint runs in a
    %% connect callback (executed inside the wx event thread) and reads its
    %% spec from persistent_term, which the owner updates via paint_canvas/7.
    persistent_term:put(canvas_spec_key(Id), default_canvas_spec()),
    wxPanel:connect(Panel, paint,
                    [{callback, fun(_Ev, _Obj) -> canvas_paint_cb(Panel) end}]),
    Panel.

canvas_spec_key(Id) ->
    {campy_canvas_spec, Id}.

default_canvas_spec() ->
    {24, none, <<"#f5f6f8">>, <<"#e2e4e8">>}.

%% The synchronous painter: spec from persistent_term, size from the widget.
canvas_paint_cb(Panel) ->
    Id = wxWindow:getId(Panel),
    {Step, Marquee, Bg, Grid} =
        persistent_term:get(canvas_spec_key(Id), default_canvas_spec()),
    {CW, CH} = wxWindow:getClientSize(Panel),
    Width = erlang:max(CW, 1),
    Height = erlang:max(CH, 1),
    case os:getenv("CAMPY_DUMP") of
        "1" ->
            io:format("[dump] canvas paint ~p ~px~p step=~p bg=~s grid=~s "
                     "marquee=~p~n",
                      [Id, Width, Height, Step, Bg, Grid, Marquee]);
        _ -> ok
    end,
    DC = wxPaintDC:new(Panel),
    %% Fill with a clip-limited rectangle, NOT wxDC:clear(): clear ignores
    %% the damage region, so every partial repaint (a moved child window)
    %% would wipe the grid everywhere and redraw it only in the small
    %% damaged strip. A rectangle obeys the clip, so partial paints stay
    %% consistent with what is already on screen.
    Brush = wxBrush:new(hex_rgb(Bg, {245, 246, 248})),
    wxDC:setBrush(DC, Brush),
    wxDC:setPen(DC, wxPen:new(hex_rgb(Bg, {245, 246, 248}))),
    wxDC:drawRectangle(DC, {0, 0, Width, Height}),
    Pen = wxPen:new(hex_rgb(Grid, {226, 228, 232})),
    wxDC:setPen(DC, Pen),
    draw_grid(DC, Width, Height, Step),
    draw_marquee(DC, Marquee),
    wxPen:destroy(Pen),
    wxBrush:destroy(Brush),
    wxPaintDC:destroy(DC),
    ok.

%% Record the canvas paint spec and queue a repaint. The actual drawing
%% happens synchronously in the paint callback (see canvas/2).

%% Paint the design canvas: background and light grid. The form is a real
%% widget (the white plate below the controls), not painted chrome, and
%% selection chrome is native grab strips - so this paint is pure backdrop.
paint_canvas(Canvas, Width, Height, GridStep, Marquee, Bg, Grid) ->
    %% Store the spec; the synchronous paint callback does the drawing.
    %% Width/Height are advisory only (the callback reads the live size).
    Id = wxWindow:getId(Canvas),
    persistent_term:put(canvas_spec_key(Id), {GridStep, Marquee, Bg, Grid}),
    wxWindow:refresh(Canvas),
    _ = {Width, Height},
    ok.

draw_marquee(_DC, none) ->
    ok;
draw_marquee(DC, {X, Y, W, H}) ->
    Blue = {45, 110, 220},
    wxDC:setBrush(DC, wxBrush:new({0, 0, 0, 0})),
    wxDC:setPen(DC, wxPen:new(Blue)),
    wxDC:drawRectangle(DC, {X - 2, Y - 2, W + 4, 2}),
    wxDC:drawRectangle(DC, {X - 2, Y + H, W + 4, 2}),
    wxDC:drawRectangle(DC, {X - 2, Y - 2, 2, H + 4}),
    wxDC:drawRectangle(DC, {X + W, Y - 2, 2, H + 4}),
    ok.

draw_grid(_DC, _Width, _Height, Step) when Step =< 0 ->
    ok;
draw_grid(DC, Width, Height, Step) ->
    lists:foreach(
        fun(X) -> wxDC:drawLine(DC, {X, 0}, {X, Height}) end,
        lists:seq(0, Width, Step)
    ),
    lists:foreach(
        fun(Y) -> wxDC:drawLine(DC, {0, Y}, {Width, Y}) end,
        lists:seq(0, Height, Step)
    ),
    ok.

%% Dev instrumentation (CAMPY_DUMP=1): one line per registered widget so the
%% live wx geometry can be read from the log without screenshots.
widget_report(Shell) ->
    {shell, _, _, Widgets, _, _, _, _} = Shell,
    Entries = lists:keysort(1,
                maps:fold(fun(_Id, W, Acc) ->
                              [{element(5, W), W} | Acc]
                          end, [], Widgets)),
    lists:foreach(
      fun({_ViewId, W}) ->
              {widget, Ref, Kind, _WxId, ViewId, Parent, _Props, _Events,
               _Children, _Sizer, Layout, _Border, _Grow} = W,
              case Kind of
                  <<"canvas">> ->
                      Kids = wxWindow:getChildren(Ref),
                      Info = [begin
                                   KId = wxWindow:getId(K),
                                   KParent = try wxWindow:getId(
                                                   wxWindow:getParent(K))
                                               catch _:_ -> -1 end,
                                   try
                                       {KX, KY, KW, KH} = wxWindow:getRect(K),
                                       io_lib:format("#~p(p~p) ~p,~p ~px~p",
                                                     [KId, KParent, KX, KY,
                                                      KW, KH])
                                   catch _:_ ->
                                       io_lib:format("#~p(p~p) ?",
                                                     [KId, KParent])
                                   end
                               end || K <- Kids],
                      io:format("[dump] canvas ~s(#~p) children: ~s~n",
                                [ViewId, wxWindow:getId(Ref),
                                 lists:join($\s, Info)]);
                  <<"label">> ->
                      io:format("[dump] label ~s text=~p~n",
                                [ViewId, wxWindow:getLabel(Ref)]);
                  <<"button">> ->
                      io:format("[dump] button ~s text=~p~n",
                                [ViewId, wxWindow:getLabel(Ref)]);
                  <<"text">> ->
                      io:format("[dump] text ~s value=~p~n",
                                [ViewId, wxTextCtrl:getValue(Ref)]);
                  _ -> ok
              end,
              ParentTxt = case Parent of {some, P} -> P; none -> <<"root">> end,
              Rect = case catch wxWindow:getRect(Ref) of
                         {X, Y, W2, H2} ->
                             unicode:characters_to_binary(
                               io_lib:format("~p,~p ~px~p", [X, Y, W2, H2]));
                         _ -> <<"?">>
                     end,
              Shown = case catch wxWindow:isShown(Ref) of
                          true -> <<"shown">>;
                          false -> <<"HIDDEN">>;
                          _ -> <<"?">>
                      end,
              io:format("[dump] ~s ~s parent=~s layout=~s rect=~s ~s~n",
                        [Kind, ViewId, ParentTxt, Layout, Rect, Shown])
      end, Entries),
    PlateInfo = case get(campy_plates) of
                    undefined -> <<"no plate">>;
                    M -> io_lib:format("~b plate(s)", [maps:size(M)])
                end,
    io:format("[dump] plates: ~s~n", [PlateInfo]),
    ok.

%% Design-mode input: every widget reports selection through left_down. Command
%% events are deliberately not connected: on a Ctrl-click they would fire after
%% the toggle and collapse the multi-selection back to one control.

connect_design(Ref, Kind) ->
    %% A design control owns press, motion, and release. GTK's implicit grab
    %% delivers motion/release to the pressed widget even after the pointer
    %% leaves it, so a body drag works without capturing the canvas. Capturing
    %% the canvas from inside a child's press lost the matching release on GTK
    %% and left every later click routed to the canvas.
    case Kind of
        <<"canvas">> -> connect_mouse(wxPanel, Ref);
        <<"panel">> -> connect_mouse(wxPanel, Ref);
        <<"group">> -> connect_mouse(wxPanel, Ref);
        <<"page">> -> connect_mouse(wxPanel, Ref);
        <<"label">> -> connect_mouse(wxStaticText, Ref);
        <<"text">> -> connect_mouse(wxTextCtrl, Ref);
        <<"memo">> -> connect_mouse(wxTextCtrl, Ref);
        <<"slider">> -> connect_mouse(wxSlider, Ref);
        <<"progress">> -> connect_mouse(wxGauge, Ref);
        <<"picture">> -> connect_mouse(wxStaticBitmap, Ref);
        <<"button">> -> connect_mouse(wxButton, Ref);
        <<"checkbox">> -> connect_mouse(wxCheckBox, Ref);
        <<"radio">> -> connect_mouse(wxRadioButton, Ref);
        <<"choice">> -> connect_mouse(wxChoice, Ref);
        <<"list">> -> connect_mouse(wxListBox, Ref);
        <<"tree">> -> connect_mouse(wxTreeCtrl, Ref);
        <<"grid">> -> connect_mouse(wxGrid, Ref);
        <<"editor">> -> connect_mouse(wxStyledTextCtrl, Ref);
        _ -> catch wxWindow:connect(Ref, left_down, [])
    end,
    ok.

connect_mouse(Module, Ref) ->
    catch Module:connect(Ref, left_down, []),
    catch Module:connect(Ref, motion, []),
    catch Module:connect(Ref, left_up, []),
    catch Module:connect(Ref, command_menu_selected, []),
    ok.

%% Frame accelerator table. Accelerators are matched before character
%% generation, so Ctrl+S and Ctrl+1 work even while wxGrid's cell editor has
%% keyboard focus (char_hook is not delivered in that state). Text-editing
%% shortcuts are omitted while Code/Source is active so Scintilla keeps them.
set_shortcuts(Frame, Editing) ->
    Entries = accelerator_entries(Editing),
    Table = wxAcceleratorTable:new(length(Entries), Entries),
    %% Drop the previous table: it is replaced on every page switch.
    case get(campy_accel_table) of
        {OldTable, _OldEntries} -> catch wxAcceleratorTable:destroy(OldTable), ok;
        _ -> ok
    end,
    catch wxWindow:setAcceleratorTable(Frame, Table),
    %% Keep both the table and its entries alive for the window's lifetime.
    put(campy_accel_table, {Table, Entries}),
    %% char_hook sees Ctrl+C/X/V/Y/D/Delete before GTK's text-widget
    %% bindings consume them. It is only enabled on the Form page; Code/Source
    %% keep their editor shortcuts. The app deliberately ignores the keys that
    %% the accelerator table already handles (save, quit, pages, escape).
    ok.

%% Apply the current accelerator table to a child as well. wx only consults
%% the focused window's table, so a native design control must carry the same
%% table for Ctrl+C/V/Y to reach the frame while it has focus.
apply_shortcuts(Ref) ->
    case get(campy_accel_table) of
        {Table, _Entries} ->
            catch wxWindow:setAcceleratorTable(Ref, Table),
            ok;
        _ -> ok
    end.

accelerator_entries(_Editing) ->
    [
        accel(?wxACCEL_CTRL, $S, 9101),
        accel(?wxACCEL_CTRL, $Q, 9102),
        accel(?wxACCEL_CTRL, $1, 9111),
        accel(?wxACCEL_CTRL, $2, 9112),
        accel(?wxACCEL_CTRL, $3, 9113),
        accel(0, ?WXK_ESCAPE, 9114),
        %% Language server helpers, active on every page: F12 jumps to the
        %% declaration under the Code editor's caret, Ctrl+Space completes.
        accel(?wxACCEL_NORMAL, ?WXK_F12, 9115),
        accel(?wxACCEL_CTRL, ?WXK_SPACE, 9116)
    ].

accel(Flags, KeyCode, Command) ->
    wxAcceleratorEntry:new([
        {flags, Flags},
        {keyCode, KeyCode},
        {cmd, Command}
    ]).

shortcut_action(9101) -> <<"save">>;
shortcut_action(9102) -> <<"quit">>;
shortcut_action(9103) -> <<"undo">>;
shortcut_action(9104) -> <<"redo">>;
shortcut_action(9105) -> <<"redo">>;
shortcut_action(9106) -> <<"cut">>;
shortcut_action(9107) -> <<"copy">>;
shortcut_action(9108) -> <<"paste">>;
shortcut_action(9109) -> <<"duplicate">>;
shortcut_action(9110) -> <<"delete">>;
shortcut_action(9111) -> <<"form">>;
shortcut_action(9112) -> <<"code">>;
shortcut_action(9113) -> <<"source">>;
shortcut_action(9114) -> <<"escape">>;
shortcut_action(9115) -> <<"definition">>;
shortcut_action(9116) -> <<"complete">>;
shortcut_action(_) -> false.

capture(Ref) ->
    wxWindow:captureMouse(Ref),
    ok.

%% Role 0..7 resize edges, 8 move, none/other restores the arrow. Cursors are
%% cached per kind; creating one per motion event is wasteful.
set_cursor(Ref, Role) when Role >= 0, Role =< 8 ->
    wxWindow:setCursor(Ref, cursor_for(Role)),
    ok;
set_cursor(Ref, _Role) ->
    wxWindow:setCursor(Ref, cursor_for(arrow)),
    ok.

%% Cursors are created once and cached: set_cursor runs on every motion event
%% while dragging a handle, and each wxCursor is a GDI/GTK object.
cursor_for(Kind) ->
    Cursors = case get(campy_cursors) of
        undefined -> #{};
        M -> M
    end,
    case maps:find(Kind, Cursors) of
        {ok, Cursor} ->
            Cursor;
        error ->
            Cursor = new_cursor(Kind),
            put(campy_cursors, maps:put(Kind, Cursor, Cursors)),
            Cursor
    end.

new_cursor(8) -> wxCursor:new(?wxCURSOR_SIZING);
new_cursor(arrow) -> wxCursor:new(?wxCURSOR_ARROW);
new_cursor(Role) -> wxCursor:new(handle_cursor(Role)).

handle_cursor(Role) when Role =:= 0; Role =:= 4 -> ?wxCURSOR_SIZENWSE;
handle_cursor(Role) when Role =:= 2; Role =:= 6 -> ?wxCURSOR_SIZENESW;
handle_cursor(Role) when Role =:= 1; Role =:= 5 -> ?wxCURSOR_SIZENS;
handle_cursor(_) -> ?wxCURSOR_SIZEWE.

release(Ref) ->
    catch wxWindow:releaseMouse(Ref),
    ok.

%% Release whichever window currently owns the GTK mouse grab. A native child
%% (or a raised mini-frame) can end up as the capture window even after the
%% canvas looked captured; using wxWindow:getCapture/0 is the reliable path.
release_capture() ->
    try wxWindow:getCapture() of
        undefined -> ok;
        Ref -> catch wxWindow:releaseMouse(Ref), ok
    catch
        _:_ -> ok
    end.

%% Events

connect(Ref, <<"editor">>) ->
    %% Key events flow to the IDE so the clipboard/undo keys work
    %% deterministically on this GTK build; {skip, true} lets Scintilla
    %% process everything as usual too. Text changes are delivered too:
    %% the Code page adopts the buffer as the model's handlers, so refresh
    %% never reverts typed text and the language server sees live edits.
    wxStyledTextCtrl:connect(Ref, key_down, [{skip, true}]),
    catch wxStyledTextCtrl:connect(Ref, stc_change, []),
    ok;
connect(Ref, <<"window">>) ->
    wxFrame:connect(Ref, close_window, []),
    catch wxFrame:connect(Ref, command_menu_selected, []),
    catch wxFrame:connect(Ref, size, []),
    catch wxFrame:connect(Ref, move, []);
    %% char_hook is intentionally not connected: on this GTK build it consumes
    %% character events for wxGrid's editor (and fires alongside accelerators,
    %% double-applying Undo). The accelerator table below is the single
    %% shortcut path and is rebuilt when Form/Code/Source changes.
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
connect(Ref, <<"slider">>) ->
    wxSlider:connect(Ref, command_slider_updated, []);
connect(Ref, <<"menu">>) ->
    wxMenu:connect(Ref, command_menu_selected, []);
connect(Ref, <<"toolbar">>) ->
    wxToolBar:connect(Ref, command_menu_selected, []);
connect(Ref, <<"tree">>) ->
    wxTreeCtrl:connect(Ref, command_tree_sel_changed, []);
connect(Ref, <<"grid">>) ->
    wxGrid:connect(Ref, grid_cell_changed, []),
    %% Cell selection drives the enum dropdown popups.
    catch wxGrid:connect(Ref, grid_select_cell, []);
connect(Ref, <<"notebook">>) ->
    wxNotebook:connect(Ref, command_notebook_page_changed, []),
    catch wxNotebook:connect(Ref, char_hook, [{skip, true}]);
connect(Ref, <<"list">>) ->
    wxListBox:connect(Ref, command_listbox_selected, []),
    catch wxListBox:connect(Ref, char_hook, [{skip, true}]);
connect(_Ref, _Kind) ->
    ok.

%% The process that owns the widgets receives `#wx{}` records. This is the
%% single receive point: wx events are normalised, everything else is handed
%% back untouched so the caller can run its own message protocol.

next_message(Timeout) ->
    receive
        {wx, Id, Obj, _UserData, Event} when is_tuple(Event) ->
            case element(1, Event) of
                wxKey ->
                    {key_event, KeyCode, Control, Shift, Alt} = key_event(Event),
                    %% The connection is made with `{skip, true}` so the
                    %% focused control (Scintilla, a grid editor, ...) still
                    %% receives normal text input. The app only claims its
                    %% own shortcuts.
                    {key_event, KeyCode, Control, Shift, Alt};
                wxMouse ->
                    Type = atom_to_binary(element(2, Event), utf8),
                    {mouse_event, Id, Type, element(3, Event), element(4, Event),
                     element(8, Event) =:= true};
                wxGrid ->
                    case element(2, Event) of
                        Type when Type =:= command_grid_select_cell;
                                  Type =:= grid_select_cell ->
                            %% An enum dropdown pops open as soon as its cell
                            %% is selected; other cell selects are swallowed.
                            maybe_enum_popup(
                              Obj, element(3, Event), element(4, Event));
                        _ ->
                            % Use the event's row/col, not the grid cursor:
                            % Enter moves the cursor to the next cell before
                            % the app reads it.
                            Row = element(3, Event),
                            Col = element(4, Event),
                            Text = unicode:characters_to_binary(
                                wxGrid:getCellValue(Obj, Row, Col)),
                            {grid_event, Id, Row, Col, Text}
                    end;
                wxStyledText ->
                    case element(2, Event) of
                        stc_autocomp_selection ->
                            %% The picked jump entry. The event's text field
                            %% carries it; fall back to the popup's selection
                            %% index, then to the stored entries.
                            Text = jump_pick(Obj, Event),
                            {stc_jump, Id, Text};
                        stc_change ->
                            %% A text change in any Scintilla editor. Routed
                            %% as a plain change event on the editor's view
                            %% id; the IDE adopts Code-page typing from it.
                            {wx_event, Id, <<"change">>};
                        _ ->
                            {wx_event, Id, event_type(Event)}
                    end;
                wxCommand ->
                    case element(2, Event) of
                        command_listbox_selected ->
                            case enum_popup_pick(Id, element(4, Event)) of
                                idle -> {wx_event, Id, event_type(Event)};
                                Picked -> Picked
                            end;
                        _ ->
                            case shortcut_action(Id) of
                                false ->
                                    {wx_event, Id, event_type(Event)};
                                Action ->
                                    {shortcut_event, Action}
                            end
                    end;
                _ ->
                    {wx_event, Id, event_type(Event)}
            end;
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

%% Frame-level `char_hook`: the app sees one normalised key message per press.
%% Letters are lower-cased; Ctrl/Shift still distinguish the binding.
key_event(Event) ->
    Code = element(5, Event),
    Control = element(6, Event) =:= true,
    Shift = element(7, Event) =:= true,
    Alt = element(8, Event) =:= true,
    {key_event, key_name(Code), Control, Shift, Alt}.

key_name(Code) when Code >= $A, Code =< $Z -> <<(Code + 32)>>;
key_name(Code) when Code >= $a, Code =< $z -> <<Code>>;
key_name(Code) when Code >= $0, Code =< $9 -> <<Code>>;
key_name(8) -> <<"back">>;
key_name(9) -> <<"tab">>;
key_name(13) -> <<"enter">>;
key_name(27) -> <<"escape">>;
key_name(127) -> <<"delete">>;
key_name(Code) -> integer_to_binary(Code).

event_type(Event) when is_tuple(Event) ->
    case element(1, Event) of
        % wxGrid edits arrive as wxGridEvent records, not wxCommandEvent.
        wxGrid -> <<"command">>;
        % Notebook page changes arrive as wxBookCtrl records, not wxCommand;
        % only the (post-change) page_changed selection is a logical command.
        wxBookCtrl -> <<"command">>;
        % Tree selection is a wxTreeEvent; only the selection change is a
        % logical command. Expanding/collapsing must not fire `select`.
        wxTree ->
            case element(2, Event) of
                command_tree_sel_changed -> <<"command">>;
                _ -> <<"other">>
            end;
        wxCommand -> <<"command">>;
        wxClose -> <<"close">>;
        wxSize -> <<"size">>;
        wxMove -> <<"move">>;
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
