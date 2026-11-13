-module(campy_form_upgrade_ffi).
-export([write_v8_project/1]).

%% Writes a genuine v8 project file: 11-element form tuples, no transparency
%% map. Gleam tests use it to exercise the on-disk upgrade path and prove the
%% current emitter can render the upgraded forms.
write_v8_project(Path) ->
    Controls = [
        {control, <<"pic-1">>, <<"pic1">>, picture, 20, 20, 200, 150,
                  <<"assets/cat.png">>, true, true},
        {control, <<"button-1">>, <<"button1">>, button, 20, 180, 110, 32,
                  <<"Click">>, true, true}
    ],
    Form = {form, <<"campy.form">>, <<"Legacy">>, 400, 300, free,
                  Controls, [], [], [], []},
    Module = {module, <<"main">>, <<"Main">>, Form, <<"// handlers\n">>},
    Term = {project, 8, <<"Legacy">>, [Module], <<"/tmp/legacy.campy">>, <<>>},
    file:write_file(filename:absname(Path), term_to_binary(Term, [compressed])).
