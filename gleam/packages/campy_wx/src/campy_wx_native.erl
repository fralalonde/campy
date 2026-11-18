-module(campy_wx_native).
-export([
    new_app/0, destroy_app/0, frame/4, show/1, connect/2, next_message/1,
    panel/2, label/3, button/3, checkbox/3, radio/3, choice/2, listbox/2,
    textctrl/3, memo/3, slider/5, gauge/3, picture/3,
    box_sizer/1, add/5, insert/6, detach/2, set_sizer/2, layout_sizer/2,
    menubar/0, menu/0, menuitem/3, append_menu/3, set_menubar/2,
    toolbar/1, tool/3, tool_separator/1, realize_toolbar/1,
    statusbar/1, set_status/2,
    notebook/2, page/3, notebook_selection/1, select_page/2,
    tree/2, tree_set/2, tree_selected_key/1,
    grid/2, grid_set/2, grid_configure/5, grid_cell/1,
    grid_number_cell/4, grid_text_cell/3, grid_read_only/4,
    editor/2, editor_set/3, editor_show_end/1,
    open_dialog/2, save_dialog/3, show_message/3,
    set_tooltip/2,
    canvas/2, paint_canvas/7, connect_design/2,
    capture/1, release/1, release_capture/0, set_cursor/2, set_shortcuts/2,
    freeze/1, thaw/1, layout/1, move/3, resize/3, set_min_size/3,
    set_label/2, set_text/2, set_int/3, set_bool/3, set_selection/3,
    set_items/3, set_enabled/2, set_visible/2, set_background/4, refresh_window/1, focus/1,
    focus_ignoring_children/1, set_editable/2, raise/1, destroy/1, apply_shortcuts/1,
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

%% Refresh queues an expose; update flushes the pending paint immediately,
%% which is what text changed outside a wx event needs.
set_background(Ref, R, G, B) ->
    wxWindow:setBackgroundColour(Ref, {R, G, B}),
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
            ?wxTB_TEXT bor ?wxTB_NOICONS bor ?wxTB_HORZ_LAYOUT bor
                ?wxTB_FLAT bor ?wxTB_NODIVIDER}
    ]).

tool(ToolBar, Id, Label) ->
    wxToolBar:addTool(ToolBar, Id, Label, wxBitmap:new({16, 16})),
    ToolBar.

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
    ok.

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
            grid_fit_value_column(Grid, 110)
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
    ok.

%% Show the end of a freshly rewritten source file, so an appended ABI stub is
%% visible immediately after the event click opens the Code page.
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

%% Designer canvas

canvas(Parent, Id) ->
    Panel = wxPanel:new(Parent, [{winid, Id}, {style, ?wxFULL_REPAINT_ON_RESIZE}]),
    wxPanel:setBackgroundColour(Panel, {245, 246, 248}),
    wxPanel:connect(Panel, paint, []),
    Panel.

%% Paint the design canvas: background, grid, border, then the selection
%% chrome and the active marquee. The chrome lives in the canvas' own DC, so
%% there are no extra top-level windows (they appeared as separate taskbar
%% entries on Wayland) and nothing can swallow pointer input.
paint_canvas(Canvas, Width, Height, GridStep, Selection, Marquee, Single) ->
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
    draw_marquee(DC, Marquee),
    draw_selection(DC, Selection, Single),
    wxBufferedPaintDC:destroy(DC),
    ok.

%% #x/y/w/h tuples arrive as {x, y, w, h}; Selection is none | {X, Y, W, H}.
draw_selection(_DC, none, _Single) ->
    ok;
draw_selection(DC, {X, Y, W, H}, Single) ->
    Blue = {45, 110, 220},
    wxDC:setBrush(DC, wxBrush:new(Blue)),
    wxDC:setPen(DC, wxPen:new(Blue)),
    wxDC:drawRectangle(DC, {X - 2, Y - 2, W + 4, 2}),
    wxDC:drawRectangle(DC, {X - 2, Y + H, W + 4, 2}),
    wxDC:drawRectangle(DC, {X - 2, Y - 2, 2, H + 4}),
    wxDC:drawRectangle(DC, {X + W, Y - 2, 2, H + 4}),
    case Single of
        true -> draw_handles(DC, {X, Y, W, H}, Blue);
        false -> ok
    end,
    ok.

draw_handles(DC, {X, Y, W, H}, Blue) ->
    wxDC:setBrush(DC, wxBrush:new({245, 246, 248})),
    wxDC:setPen(DC, wxPen:new(Blue)),
    lists:foreach(
        fun({HX, HY}) -> wxDC:drawRectangle(DC, {HX - 4, HY - 4, 9, 9}) end,
        [
            {X, Y},
            {X + W div 2, Y},
            {X + W, Y},
            {X + W, Y + H div 2},
            {X + W, Y + H},
            {X + W div 2, Y + H},
            {X, Y + H},
            {X, Y + H div 2}
        ]
    ),
    wxDC:setBrush(DC, wxBrush:new(Blue)),
    wxDC:drawRectangle(DC, {X + 4, Y + 4, 36, 12}),
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
        accel(0, ?WXK_ESCAPE, 9114)
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
    wxWindow:setCursor(Ref, wxCursor:new(?wxCURSOR_ARROW)),
    ok.

cursor_for(8) -> wxCursor:new(?wxCURSOR_SIZING);
cursor_for(Role) -> wxCursor:new(handle_cursor(Role)).

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
    wxGrid:connect(Ref, grid_cell_changed, []);
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
                    % Use the event's row/col, not the grid cursor: Enter moves
                    % the cursor to the next cell before the app reads it.
                    % #wxGrid type, row, col, pos, ...
                    Row = element(3, Event),
                    Col = element(4, Event),
                    Text = unicode:characters_to_binary(
                        wxGrid:getCellValue(Obj, Row, Col)),
                    {grid_event, Id, Row, Col, Text};
                wxCommand ->
                    case shortcut_action(Id) of
                        false -> {wx_event, Id, event_type(Event)};
                        Action -> {shortcut_event, Action}
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
