-module(campy_form_ffi).
-export([save_project/2, load_project/1, save_workspace/2, load_workspace/1]).

%% Projects are stored as versioned Erlang terms. Project file paths are
%% relative to CAMPY_ROOT (set by scripts/workspace.py) unless absolute.
%%
%% Decoding is `binary_to_term/1` rather than `binary_to_term/2` with `[safe]`:
%% the terms store the form model's own atoms (`panel`, `free`, `slider`, …),
%% and a Gleam-compiled program holds those as binaries rather than atoms, so
%% at boot the atom table never contains them and `safe` rejects every file
%% this codec wrote. Shape is still checked below (`{workspace, 1, …}` and
%% `decode_projects/2`), which is what rejects anything that is not a file of
%% ours.
%%
%% Codec v12: a module's last field is its source origin, either
%% {embedded, Source} (the source lives in this term file) or
%% {external, Path} (only the path is stored; the codec never reads it).
%% External paths are kept verbatim: callers store a path relative to the
%% project file when possible; absolute paths are allowed.
%% There is no backward-compatibility chain: files from older codecs are
%% rejected by the version check in `campy_form/project`.
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
            try binary_to_term(Binary) of
                {workspace, 1, Projects, Active, WPath} when is_list(Projects) ->
                    case decode_projects(Projects, []) of
                        {ok, Next} ->
                            {ok, {workspace, 1, Next, Active, WPath}};
                        error ->
                            {error, <<"Unsupported workspace format">>}
                    end;
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
            try binary_to_term(Binary) of
                Term ->
                    case decode_project(Term) of
                        {ok, Project} -> {ok, Project};
                        error -> {error, <<"Unsupported project format">>}
                    end
            catch
                _:_ -> {error, <<"Invalid project file">>}
            end;
        {error, enoent} -> {error, <<"Project file not found">>};
        {error, Reason} -> error_text(Reason)
    end.

decode_projects([], Decoded) ->
    {ok, lists:reverse(Decoded)};
decode_projects([Project | Rest], Decoded) ->
    case decode_project(Project) of
        {ok, Next} -> decode_projects(Rest, [Next | Decoded]);
        error -> error
    end;
decode_projects(_, _) ->
    error.

decode_project({project, Version, Title, Modules, Path, Icon})
  when is_integer(Version), is_binary(Title), is_list(Modules),
       is_binary(Path), is_binary(Icon) ->
    case decode_modules(Modules, []) of
        {ok, Next} ->
            {ok, {project, Version, Title, Next, Path, Icon}};
        error ->
            error
    end;
decode_project(_) ->
    error.

decode_modules([], Decoded) ->
    {ok, lists:reverse(Decoded)};
decode_modules([Module | Rest], Decoded) ->
    case decode_module(Module) of
        {ok, Next} -> decode_modules(Rest, [Next | Decoded]);
        error -> error
    end;
decode_modules(_, _) ->
    error.

decode_module({module, Id, Name, Form, Origin})
  when is_binary(Id), is_binary(Name) ->
    case {form_shape(Form), origin_shape(Origin)} of
        {true, true} -> {ok, {module, Id, Name, Form, Origin}};
        _ -> error
    end;
decode_module(_) ->
    error.

form_shape(Form) when is_tuple(Form), tuple_size(Form) > 1,
                      element(1, Form) =:= form ->
    true;
form_shape(_) ->
    false.

origin_shape({embedded, Source}) when is_binary(Source) ->
    true;
origin_shape({external, Path}) when is_binary(Path) ->
    true;
origin_shape(_) ->
    false.

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
