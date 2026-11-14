-module(campy_form_ffi).
-export([save_project/2, load_project/1, save_workspace/2, load_workspace/1]).

%% Projects are stored as versioned Erlang terms. Paths are relative to
%% CAMPY_ROOT (set by scripts/workspace.py) unless absolute.
save_project(Path, Project) ->
    Full = resolve(Path),
    case filelib:ensure_dir(Full) of
        ok ->
            case file:write_file(Full, term_to_binary(Project, [compressed])) of
                ok -> {ok, nil};
                {error, Reason} -> error_text(Reason)
            end;
        {error, Reason} -> error_text(Reason)
    end.

save_workspace(Path, Workspace) ->
    save_project(Path, Workspace).

load_workspace(Path) ->
    Full = resolve(Path),
    case file:read_file(Full) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                {workspace, 1, Projects, Active, WPath} when is_list(Projects) ->
                    Upgraded = [case upgrade(Project) of
                                    {ok, Next} -> Next;
                                    error -> Project
                                end || Project <- Projects],
                    {ok, {workspace, 1, Upgraded, Active, WPath}};
                _ ->
                    {error, <<"Unsupported workspace format">>}
            catch
                _:_ -> {error, <<"Invalid workspace file">>}
            end;
        {error, enoent} ->
            {error, <<"Workspace file not found">>};
        {error, Reason} ->
            error_text(Reason)
    end.

load_project(Path) ->
    Full = resolve(Path),
    case file:read_file(Full) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                Term ->
                    case upgrade(Term) of
                        {ok, Project} -> {ok, Project};
                        error -> {error, <<"Unsupported project format">>}
                    end
            catch
                _:_ -> {error, <<"Invalid project file">>}
            end;
        {error, enoent} -> {error, <<"Project file not found">>};
        {error, Reason} -> error_text(Reason)
    end.

%% v1: single form/source. v2: modules. v3: form layout. v4: parent map for
%% container adoption. v5: per-control alignment. v6: per-container layouts.
%% v7: project icon. v8: parent border margins. v9: picture transparency.
%% v10: per-control colors. v11: per-control property values (CCL schema).
%% Older files upgrade to v11.
upgrade({project, 1, Form, Source, Path}) ->
    {ok, {project, 11, <<"Campy">>,
          [{module, <<"main">>, <<"Main">>, upgrade_v1_form(Form), Source}],
          Path, icon_for(<<"Campy">>, Path)}};

upgrade({project, 2, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v2) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 3, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v3) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 4, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v4) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 5, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v5) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 6, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v6) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 7, Title, Modules, Path, Icon}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v6) || Module <- Modules],
          Path, Icon}};
upgrade({project, 8, Title, Modules, Path, Icon}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v6) || Module <- Modules],
          Path, Icon}};
upgrade({project, 9, Title, Modules, Path, Icon}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v9) || Module <- Modules],
          Path, Icon}};
upgrade({project, 10, Title, Modules, Path, Icon}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v10) || Module <- Modules],
          Path, Icon}};
upgrade({project, 11, Title, Modules, Path, Icon}) when is_list(Modules) ->
    {ok, {project, 11, Title, [upgrade_module(Module, v11) || Module <- Modules],
          Path, Icon}};
upgrade(_) ->
    error.

icon_for(<<"Campy">>, _Path) -> <<"assets/camping-tent.png">>;
icon_for(_Title, Path) ->
    case filename:basename(Path) of
        <<"campy.campy">> -> <<"assets/camping-tent.png">>;
        _ -> <<>>
    end.

upgrade_module({module, Id, Name, Form, Source}, Version) ->
    {module, Id, Name, upgrade_form(upgrade_controls(Form), Version), Source}.

%% Applies the v11 control upgrade to every control of a form tuple.
upgrade_controls(Form) when is_tuple(Form), element(1, Form) =:= form ->
    Controls = [upgrade_control(C) || C <- element(7, Form)],
    setelement(7, Form, Controls);
upgrade_controls(Form) ->
    Form.

%% v11: controls gain per-control property values (CCL schema). Applied to
%% every version so old control tuples without props pick up an empty list.
upgrade_control({control, Id, Name, Kind, X, Y, W, H, Text, Enabled, Visible}) ->
    {control, Id, Name, Kind, X, Y, W, H, Text, Enabled, Visible, []};
upgrade_control(Control) ->
    Control.

upgrade_v1_form(Form) ->
    upgrade_form(upgrade_controls(Form), v2).

upgrade_form({form, Id, Title, Width, Height, Controls}, v2) ->
    {form, Id, Title, Width, Height, 'free', Controls, [], [], [], [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls}, v3) ->
    {form, Id, Title, Width, Height, Layout, Controls, [], [], [], [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents}, v4) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, [], [], [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns}, v5) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, [], [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts}, v6) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts, [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts, Borders}, _Version) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts, Borders, [], []};
%% v9: per-control transparencies (12-element form, no colors yet).
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts, Borders, Transparencies}, _Version) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, Layouts, Borders, Transparencies, []};
upgrade_form({form, _, _, _, _, _, _, _, _, _, _, _, _} = Form, _Version) ->
    Form.

resolve(Path) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ ->
            Root = case os:getenv("CAMPY_ROOT") of
                false -> ".";
                Value -> Value
            end,
            filename:join([Root, Path])
    end.

error_text(Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
