-module(campy_wx_native).
-export([
    new_app/0, destroy_app/0, frame/4, show/1, connect/2, next_message/1,
    panel/2, label/3, button/3, checkbox/3, radio/3, choice/2, listbox/2,
    textctrl/3, memo/3, slider/5, gauge/3, picture/3,
    box_sizer/1, add/5, insert/6, detach/2, set_sizer/2,
    menubar/0, menu/0, menuitem/3, append_menu/3, set_menubar/2,
    toolbar/1, tool/3, realize_toolbar/1,
    statusbar/1, set_status/2,
    notebook/2, page/3, notebook_selection/1, select_page/2,
    tree/2, tree_set/2, tree_selected_key/1,
    grid/2, grid_set/2, grid_cell/1,
    editor/2, editor_set/3,
    open_dialog/2, save_dialog/3,
    canvas/2, paint_canvas/4, connect_design/2,
    handles_create/2, handle_place/6, handle_show/2, handle_raise/1,
    capture/1, release/1,
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

move(Ref, X, Y) ->
    wxWindow:move(Ref, {X, Y}),
    ok.

resize(Ref, Width, Height) when Width > 0, Height > 0 ->
    wxWindow:setSize(Ref, {Width, Height}),
    ok;
resize(_Ref, _Width, _Height) ->
    ok.

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
    wxFrame:createToolBar(Frame, [{style, ?wxTB_TEXT}]).

tool(ToolBar, Id, Label) ->
    wxToolBar:addTool(ToolBar, Id, Label, wxBitmap:new({16, 16})),
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

grid_set(Grid, Rows) ->
    RowCount = length(Rows),
    ColCount = case Rows of
        [] -> 0;
        [First | _] -> length(First)
    end,
    case ColCount of
        0 -> ok;
        _ ->
            adjust_grid(Grid, RowCount, ColCount),
            wxGrid:beginBatch(Grid),
            set_grid_rows(Grid, Rows, 0),
            wxGrid:endBatch(Grid)
    end,
    ok.

adjust_grid(Grid, RowCount, ColCount) ->
    case {wxGrid:getNumberRows(Grid), wxGrid:getNumberCols(Grid)} of
        {0, 0} ->
            wxGrid:createGrid(Grid, RowCount, ColCount);
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

editor(Parent, Id) ->
    Editor = wxStyledTextCtrl:new(Parent, [{id, Id}]),
    wxStyledTextCtrl:styleSetFaceName(Editor, 0, <<"monospace">>),
    wxStyledTextCtrl:styleSetSize(Editor, 0, 11),
    wxStyledTextCtrl:styleClearAll(Editor),
    wxStyledTextCtrl:setMarginType(Editor, 0, ?wxSTC_MARGIN_NUMBER),
    wxStyledTextCtrl:setMarginWidth(Editor, 0, 40),
    Editor.

editor_set(Editor, Text, ReadOnly) ->
    wxStyledTextCtrl:setText(Editor, Text),
    wxStyledTextCtrl:setReadOnly(Editor, ReadOnly),
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

%% Designer canvas

canvas(Parent, Id) ->
    Panel = wxPanel:new(Parent, [{winid, Id}, {style, ?wxFULL_REPAINT_ON_RESIZE}]),
    wxPanel:setBackgroundColour(Panel, {245, 246, 248}),
    wxPanel:connect(Panel, paint, []),
    Panel.

paint_canvas(Canvas, Width, Height, GridStep) ->
    DC = wxBufferedPaintDC:new(Canvas),
    wxDC:setBackground(DC, wxBrush:new({245, 246, 248})),
    wxDC:clear(DC),
    wxDC:setPen(DC, wxPen:new({226, 228, 232})),
    draw_grid(DC, Width, Height, GridStep),
    wxDC:setPen(DC, wxPen:new({180, 184, 190})),
    wxDC:drawLine(DC, {0, 0}, {Width - 1, 0}),
    wxDC:drawLine(DC, {Width - 1, 0}, {Width - 1, Height - 1}),
    wxDC:drawLine(DC, {Width - 1, Height - 1}, {0, Height - 1}),
    wxDC:drawLine(DC, {0, Height - 1}, {0, 0}),
    wxBufferedPaintDC:destroy(DC),
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

%% Design-mode input: any click selects; button-like controls report through
%% their command event, everything else through left_down.

connect_design(Ref, Kind) ->
    case Kind of
        <<"canvas">> -> catch wxPanel:connect(Ref, left_down, []);
        <<"panel">> -> catch wxPanel:connect(Ref, left_down, []);
        <<"group">> -> catch wxPanel:connect(Ref, left_down, []);
        <<"page">> -> catch wxPanel:connect(Ref, left_down, []);
        <<"label">> -> catch wxStaticText:connect(Ref, left_down, []);
        <<"text">> -> catch wxTextCtrl:connect(Ref, left_down, []);
        <<"memo">> -> catch wxTextCtrl:connect(Ref, left_down, []);
        <<"slider">> -> catch wxSlider:connect(Ref, left_down, []);
        <<"progress">> -> catch wxGauge:connect(Ref, left_down, []);
        <<"picture">> -> catch wxStaticBitmap:connect(Ref, left_down, []);
        <<"button">> ->
            catch wxButton:connect(Ref, left_down, []),
            catch wxButton:connect(Ref, command_button_clicked, []);
        <<"checkbox">> ->
            catch wxCheckBox:connect(Ref, left_down, []),
            catch wxCheckBox:connect(Ref, command_checkbox_clicked, []);
        <<"radio">> ->
            catch wxRadioButton:connect(Ref, left_down, []),
            catch wxRadioButton:connect(Ref, command_radiobutton_selected, []);
        <<"choice">> ->
            catch wxChoice:connect(Ref, left_down, []),
            catch wxChoice:connect(Ref, command_choice_selected, []);
        <<"list">> ->
            catch wxListBox:connect(Ref, left_down, []),
            catch wxListBox:connect(Ref, command_listbox_selected, []);
        _ -> catch wxWindow:connect(Ref, left_down, [])
    end,
    ok.

handles_create(Parent, Base) ->
    [create_handle(Parent, Base + Index, Index) || Index <- lists:seq(0, 8)].

create_handle(Parent, Id, 8) ->
    mini_handle(Parent, Id, {36, 12}, {196, 72, 60}, ?wxCURSOR_SIZING);
create_handle(Parent, Id, Role) ->
    mini_handle(Parent, Id, {12, 12}, {48, 52, 62}, handle_cursor(Role)).

mini_handle(Parent, Id, Size, Colour, Cursor) ->
    Ref = wxMiniFrame:new(Parent, Id, <<"">>, [
        {style, ?wxFRAME_NO_TASKBAR bor ?wxBORDER_NONE bor ?wxSTAY_ON_TOP},
        {size, Size}
    ]),
    wxMiniFrame:setBackgroundColour(Ref, Colour),
    wxMiniFrame:setCursor(Ref, wxCursor:new(Cursor)),
    connect_handle(Ref),
    wxWindow:hide(Ref),
    Ref.

handle_cursor(Role) when Role =:= 0; Role =:= 4 -> ?wxCURSOR_SIZENWSE;
handle_cursor(Role) when Role =:= 2; Role =:= 6 -> ?wxCURSOR_SIZENESW;
handle_cursor(Role) when Role =:= 1; Role =:= 5 -> ?wxCURSOR_SIZENS;
handle_cursor(_) -> ?wxCURSOR_SIZEWE.

connect_handle(Ref) ->
    catch wxMiniFrame:connect(Ref, left_down, []),
    catch wxMiniFrame:connect(Ref, motion, []),
    catch wxMiniFrame:connect(Ref, left_up, []),
    ok.

capture(Ref) ->
    wxWindow:captureMouse(Ref),
    ok.

release(Ref) ->
    catch wxWindow:releaseMouse(Ref),
    ok.

handle_place(Canvas, Ref, X, Y, Width, Height) ->
    {CX, CY} = wxWindow:getScreenPosition(Canvas),
    wxWindow:move(Ref, {CX + X, CY + Y}),
    wxWindow:setSize(Ref, {Width, Height}),
    ok.

handle_show(Ref, Visible) ->
    case Visible of
        true -> wxWindow:show(Ref);
        false -> wxWindow:hide(Ref)
    end,
    ok.

handle_raise(Ref) ->
    wxMiniFrame:raise(Ref),
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
connect(Ref, <<"menu">>) ->
    wxMenu:connect(Ref, command_menu_selected, []);
connect(Ref, <<"toolbar">>) ->
    wxToolBar:connect(Ref, command_menu_selected, []);
connect(Ref, <<"notebook">>) ->
    wxNotebook:connect(Ref, command_notebook_page_changed, []);
connect(Ref, <<"tree">>) ->
    wxTreeCtrl:connect(Ref, command_tree_sel_changed, []);
connect(Ref, <<"grid">>) ->
    wxGrid:connect(Ref, grid_cell_changed, []);
connect(_Ref, _Kind) ->
    ok.

%% The process that owns the widgets receives `#wx{}` records. This is the
%% single receive point: wx events are normalised, everything else is handed
%% back untouched so the caller can run its own message protocol.

next_message(Timeout) ->
    receive
        {wx, Id, _Obj, _UserData, Event} when is_tuple(Event) ->
            case element(1, Event) of
                wxMouse ->
                    Type = atom_to_binary(element(2, Event), utf8),
                    {mouse_event, Id, Type, element(3, Event), element(4, Event),
                     element(8, Event) =:= true};
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
