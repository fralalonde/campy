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
%% v7: project icon. Older files upgrade to v7.
upgrade({project, 1, Form, Source, Path}) ->
    {ok, {project, 7, <<"Campy">>,
          [{module, <<"main">>, <<"Main">>, upgrade_v1_form(Form), Source}],
          Path, icon_for(<<"Campy">>, Path)}};
upgrade({project, 2, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 7, Title, [upgrade_module(Module, v2) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 3, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 7, Title, [upgrade_module(Module, v3) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 4, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 7, Title, [upgrade_module(Module, v4) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 5, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 7, Title, [upgrade_module(Module, v5) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 6, Title, Modules, Path}) when is_list(Modules) ->
    {ok, {project, 7, Title, [upgrade_module(Module, v5) || Module <- Modules],
          Path, icon_for(Title, Path)}};
upgrade({project, 7, _Title, Modules, _Path, _Icon} = Project) when is_list(Modules) ->
    {ok, Project};
upgrade(_) ->
    error.

icon_for(<<"Campy">>, _Path) -> <<"assets/camping-tent.png">>;
icon_for(_Title, Path) ->
    case filename:basename(Path) of
        <<"campy.campy">> -> <<"assets/camping-tent.png">>;
        _ -> <<>>
    end.

upgrade_module({module, Id, Name, Form, Source}, Version) ->
    {module, Id, Name, upgrade_form(Form, Version), Source}.

upgrade_v1_form(Form) ->
    upgrade_form(Form, v2).

upgrade_form({form, Id, Title, Width, Height, Controls}, v2) ->
    {form, Id, Title, Width, Height, 'free', Controls, [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls}, v3) ->
    {form, Id, Title, Width, Height, Layout, Controls, [], [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents}, v4) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, [], []};
upgrade_form({form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns}, v5) ->
    {form, Id, Title, Width, Height, Layout, Controls, Parents, Aligns, []};
upgrade_form({form, _, _, _, _, _, _, _, _, _} = Form, _Version) ->
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
