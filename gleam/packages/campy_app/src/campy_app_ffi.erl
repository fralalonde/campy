-module(campy_app_ffi).
-export([
    init_of/1, view_of/2, dispatch/4, exported/3, migrate_of/3, load_code/2
]).

%% Load a compiled beam in place; the next dispatch call in the app module
%% runs the new code. Path is the beam file, Module the module name.
load_code(Module, Path) ->
    try
        AbsPath = filename:absname(unicode:characters_to_list(Path)),
        Bin = unwrap(file:read_file(AbsPath)),
        case code:load_binary(mod(Module), AbsPath, Bin) of
            {module, _} -> {ok, nil};
            {error, Reason} -> {error, reason(Reason)}
        end
    catch
        Class:Fail:Stack ->
            {error, reason(Class, Fail, Stack)}
    end.

unwrap({ok, Bin}) -> Bin;
unwrap({error, Reason}) -> erlang:error(Reason).

%% init/0 -> State
init_of(Module) ->
    try erlang:apply(mod(Module), init, []) of State -> {ok, State}
    catch Class:Reason:Stack ->
        {error, reason(Class, Reason, Stack)}
    end.

%% view/1 -> Document
view_of(Module, State) ->
    try erlang:apply(mod(Module), view, [State]) of Document -> {ok, Document}
    catch Class:Reason:Stack ->
        {error, reason(Class, Reason, Stack)}
    end.

%% <control>_<event>/2 -> #(State, [Effect]); a raise is contained.
dispatch(Module, Fun, State, Event) ->
    try erlang:apply(mod(Module), funname(Fun), [State, Event]) of
        {State2, Effects} -> {ok, {State2, Effects}}
    catch Class:Reason:Stack ->
        {error, reason(Class, Reason, Stack)}
    end.

exported(Module, Fun, Arity) ->
    erlang:function_exported(mod(Module), funname(Fun), Arity).

%% migrate/2 is optional: a missing migrate passes the state through so the
%% caller-provided closure (or the identity) can decide.
migrate_of(Module, State, From) ->
    M = mod(Module),
    case erlang:function_exported(M, migrate, 2) of
        true ->
            try erlang:apply(M, migrate, [State, From]) of State2 ->
                {ok, State2}
            catch Class:Reason:Stack ->
                {error, reason(Class, Reason, Stack)}
            end;
        false ->
            {ok, State}
    end.

mod(Name) when is_binary(Name) -> binary_to_atom(Name, utf8);
mod(Name) when is_atom(Name) -> Name.

funname(Name) when is_binary(Name) -> binary_to_atom(Name, utf8);
funname(Name) when is_atom(Name) -> Name.

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

reason(Class, Reason, Stack) ->
    unicode:characters_to_binary(
        io_lib:format("~p: ~p~n~p", [Class, Reason, Stack])
    ).
