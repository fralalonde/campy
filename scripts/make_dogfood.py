#!/usr/bin/env python3
"""Write the dogfood project: campy's own Gleam sources as external modules.

Run through `just dogfood`. The project term is assembled as an
`erl -noshell -eval` probe and handed to the project codec
(`campy_form_ffi`), the same way `scripts/workspace.py build-app` runs built
Gleam code from Erlang. Each module's source is an `External` path relative to
the repository root (where `projects/campy-dev.campy` lives); the codec never
reads those files, the IDE does on open.

The same term is copied to `gleam/packages/campy_form/test/dogfood_fixture.campy`
so the codec's round-trip test can read a checked-in fixture without running
this script. The working copy under `projects/` stays untracked.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FORM = ROOT / "gleam/packages/campy_form"

PROJECT_PATH = "projects/campy-dev.campy"
WORKSPACE_PATH = "projects/workspace.campy"
FIXTURE_PATH = "gleam/packages/campy_form/test/dogfood_fixture.campy"
PROJECT_TITLE = "Campy Dev"

# One module per source file campy uses to build and run itself.
MODULES = [
    ("campy-ide", "Campy IDE", "gleam/apps/campy_ide/src/campy_ide.gleam"),
    ("campy-ide-state", "Campy IDE state",
     "gleam/apps/campy_ide/src/campy_ide/state.gleam"),
    ("campy-form", "Campy Form",
     "gleam/packages/campy_form/src/campy_form.gleam"),
    ("campy-bridge", "Campy Bridge",
     "gleam/packages/campy_bridge/src/campy_bridge.gleam"),
    ("campy-ccl", "Campy CCL",
     "gleam/packages/campy_ccl/src/campy_ccl.gleam"),
]

PROBE = """
Project = {project, 12, @TITLE@, [@MODULES@], @PROJECT@, <<"">>},
Write = fun(Path, Term) ->
  case campy_form_ffi:save_project(Path, Term) of
    {ok, nil} -> io:format("Wrote ~s~n", [Path]);
    {error, Reason} ->
      io:format(standard_error, "~s: ~s~n", [Path, Reason]),
      halt(1)
  end
end,
Write(@PROJECT@, Project),
Write(@FIXTURE@, Project),
Workspace = case file:read_file(@WORKSPACE@) of
  {ok, Binary} ->
    case binary_to_term(Binary, [safe]) of
      {workspace, 1, Loaded, LoadedActive, LoadedPath} when is_list(Loaded) ->
        {workspace, 1, Loaded, LoadedActive, LoadedPath};
      _ ->
        io:format(standard_error, "Unsupported workspace format~n", []),
        halt(1)
    end;
  {error, enoent} ->
    {workspace, 1, [], <<>>, @WORKSPACE@}
end,
{workspace, 1, Existing, Active, WPath} = Workspace,
IsProject = fun(P) ->
  is_tuple(P) andalso tuple_size(P) =:= 6 andalso element(1, P) =:= project
end,
IsOurs = fun(P) -> IsProject(P) andalso element(5, P) =:= @PROJECT@ end,
Projects = case lists:any(IsOurs, Existing) of
  true ->
    [case IsOurs(P) of true -> Project; false -> P end || P <- Existing];
  false ->
    Existing ++ [Project]
end,
ActiveKnown = lists:any(IsProject, Projects) andalso
  lists:any(fun(P) -> IsProject(P) andalso element(5, P) =:= Active end, Projects),
NextActive = case ActiveKnown of true -> Active; false -> @PROJECT@ end,
case campy_form_ffi:save_workspace(@WORKSPACE@, {workspace, 1, Projects, NextActive, WPath}) of
  {ok, nil} -> io:format("Registered in ~s~n", [@WORKSPACE@]);
  {error, Reason} ->
    io:format(standard_error, "~s: ~s~n", [@WORKSPACE@, Reason]),
    halt(1)
end,
halt(0).
"""


def erl_binary(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'<<"{escaped}">>'


def control_term(control_id, name, kind, x, y, width, height, text) -> str:
    return (
        f"{{control, {erl_binary(control_id)}, {erl_binary(name)}, {kind},"
        f" {x}, {y}, {width}, {height}, {erl_binary(text)}, true, true, []}}"
    )


def module_term(module_id: str, name: str, path: str) -> str:
    label = control_term("label-1", "label1", "label", 16, 16, 208, 24, name)
    button = control_term("button-1", "button1", "button", 16, 56, 96, 32, "Run")
    form = (
        "{form, " + erl_binary("campy.form") + ", " + erl_binary(name)
        + ", 240, 160, free, [" + label + ", " + button + "],"
        " [], [], [], [], [], []}"
    )
    return (
        "{module, " + erl_binary(module_id) + ", " + erl_binary(name) + ", "
        + form + ", {external, " + erl_binary(path) + "}}"
    )


def probe() -> str:
    modules = ",\n  ".join(
        module_term(module_id, name, path)
        for module_id, name, path in MODULES
    )
    return (
        PROBE.replace("@TITLE@", erl_binary(PROJECT_TITLE))
        .replace("@MODULES@", modules)
        .replace("@PROJECT@", erl_binary(PROJECT_PATH))
        .replace("@WORKSPACE@", erl_binary(WORKSPACE_PATH))
        .replace("@FIXTURE@", erl_binary(FIXTURE_PATH))
    )


def environment() -> dict[str, str]:
    # The codec resolves relative project paths against CAMPY_ROOT.
    return {**os.environ, "CAMPY_ROOT": str(ROOT)}


def ebins() -> list[str]:
    return [str(path) for path in sorted(FORM.glob("build/dev/erlang/*/ebin"))]


def ensure_codec() -> None:
    if (FORM / "build/dev/erlang/campy_form/ebin/campy_form_ffi.beam").is_file():
        return
    subprocess.run(["gleam", "build"], cwd=FORM, env=environment(), check=True)


def main() -> None:
    ensure_codec()
    result = subprocess.run(
        ["erl", "-noshell", "-eval", probe(),
         *[path for ebin in ebins() for path in ("-pa", ebin)]],
        cwd=ROOT, env=environment(), capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(
            (result.stdout + result.stderr).strip()
            or f"Dogfood project build failed (status {result.returncode})."
        )
    print(result.stdout.strip(), flush=True)
    print(
        f"Dogfood ready: {len(MODULES)} modules in {PROJECT_PATH} "
        f"(fixture: {FIXTURE_PATH})",
        flush=True,
    )


if __name__ == "__main__":
    sys.exit(main())
