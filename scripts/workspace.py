#!/usr/bin/env python
"""Small cross-toolchain runner; public commands live in the root justfile."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import threading

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "gleam/apps/campy_ide"
PACKAGES = [
    ROOT / "gleam/packages" / name
    for name in ("campy_ui", "campy_bridge", "campy_runtime", "campy_search_box", "campy_form", "campy_ccl", "campy_manifest", "campy_app", "campy_appgen", "campy_broker", "campy_runner")
] + [APP]
NATIVE = ROOT / "gleam/packages/campy_bridge/priv/native"
RELOAD = ROOT / "generated/reload.signal"
DIST = ROOT / "generated/dist"
PROJECT = ROOT / "campy.campy"
BROKER = ROOT / "gleam/packages/campy_broker"


def toolchain_dirs() -> list[str]:
    """The directories the toolchain may live in, most specific first.

    A recipe is run from whatever shell the developer has. A rustup-managed
    `cargo` on PATH does not imply the Gleam/Erlang shims are: asdf keeps those
    in `~/.asdf/shims`, which a plain login shell or an editor's task runner
    often lacks. Adding them here is what makes `just run` work from both.
    """
    home = Path.home()
    asdf = Path(os.environ.get("ASDF_DATA_DIR", home / ".asdf")) / "shims"
    candidates = [asdf, home / ".local/bin", home / ".cargo/bin", home / "bin"]
    return [str(path) for path in candidates if path.is_dir()]


def path_with_toolchain() -> str:
    """`PATH` with the toolchain directories in front of the inherited one."""
    inherited = os.environ.get("PATH", "")
    dirs = toolchain_dirs()
    return os.pathsep.join([*dirs, inherited]) if dirs else inherited


def require_tool(name: str) -> str:
    """The path of `name`, resolved against the toolchain PATH."""
    found = shutil.which(name, path=path_with_toolchain())
    if found is None:
        raise SystemExit(
            f"{name} is not on PATH. Install it, or run this from a shell that has "
            f"it (asdf shims live in ~/.asdf/shims; `just doctor` checks the set)."
        )
    return found


def environment() -> dict[str, str]:
    env = {
        **os.environ,
        "PATH": path_with_toolchain(),
        "CAMPY_ROOT": str(ROOT),
        "CAMPY_NIF_DIR": str(NATIVE),
        "CAMPY_RELOAD_SIGNAL": str(RELOAD),
    }
    local_libs = ROOT / "generated/native-deps/usr/lib64"
    if local_libs.is_dir():
        env["LD_LIBRARY_PATH"] = str(local_libs) + os.pathsep + env.get("LD_LIBRARY_PATH", "")
    return env


def stop_process(child: subprocess.Popen) -> None:
    if child.poll() is not None:
        return
    if os.name == "posix":
        os.killpg(child.pid, signal.SIGTERM)
    else:
        # Gleam launches Erlang as a child. Killing only the CLI leaves the
        # VM (and its windows/NIF) alive after each development restart.
        subprocess.run(
            ["taskkill", "/PID", str(child.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(child.pid, signal.SIGKILL)
        else:
            child.kill()
        child.wait()


def command(args: list[str], cwd: Path = ROOT, expected: str | None = None) -> None:
    # `gleam`, `cargo`, `erl` … may only be reachable through the toolchain
    # directories, so each is resolved rather than left to the child's PATH.
    args = [require_tool(args[0]) if not os.path.isabs(args[0]) else args[0], *args[1:]]
    if expected is None:
        subprocess.run(args, cwd=cwd, env=environment(), check=True)
        return
    # Gleam 1.16 can return success after a native child crash. Require completion.
    child = subprocess.Popen(
        args, cwd=cwd, env=environment(), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, start_new_session=True,
    )
    try:
        completed = False
        for line in child.stdout:
            print(line, end="", flush=True)
            completed = completed or expected in line
        status = child.wait()
        if status:
            raise subprocess.CalledProcessError(status, args)
        if not completed:
            raise SystemExit(f"Runtime exited without completion marker: {expected!r}")
    finally:
        stop_process(child)


def nif_names() -> tuple[str, str]:
    system = platform.system()
    names = {
        "Linux": ("libcampy_bridge.so", "campy_bridge.so"),
        "Darwin": ("libcampy_bridge.dylib", "campy_bridge.so"),
        "Windows": ("campy_bridge.dll", "campy_bridge.dll"),
    }
    return names[system]


def stage_nif(profile: str = "debug") -> Path:
    source_name, target_name = nif_names()
    target = Path(os.environ.get("CARGO_TARGET_DIR", str(ROOT / "rust/target")))
    if not target.is_absolute():
        target = ROOT / target
    source = target / profile / source_name
    NATIVE.mkdir(parents=True, exist_ok=True)
    destination = NATIVE / target_name
    if not source.is_file():
        raise SystemExit(
            f"Missing {profile} NIF at {source}; "
            f"build Rust first (just build-rust{'-release' if profile == 'release' else ''})."
        )
    # Never overwrite a shared library mapped into a running BEAM VM.
    temporary = destination.with_suffix(destination.suffix + ".new")
    shutil.copy2(source, temporary)
    os.replace(temporary, destination)
    print(f"Staged {destination.relative_to(ROOT)} ({profile})", flush=True)
    return destination


def gleam(args: list[str]) -> None:
    for package in PACKAGES:
        command(["gleam", *args], cwd=package,
                expected="passed, no failures" if args[0] == "test" else None)


def clean() -> None:
    gleam(["clean"])
    shutil.rmtree(DIST, ignore_errors=True)
    for entry in NATIVE.glob("*"):
        if entry.name != ".gitkeep":
            entry.unlink()


def watch_files() -> list[Path]:
    files: list[Path] = []
    for package in PACKAGES:
        manifest = package / "gleam.toml"
        if manifest.is_file():
            files.append(manifest)
        root = package / "src"
        if root.is_dir():
            files.extend(sorted(path for path in root.rglob("*") if path.is_file()))
    return files


def files_digest(files: list[Path]) -> bytes:
    digest = hashlib.sha256()
    for path in files:
        try:
            digest.update(path.relative_to(ROOT).as_posix().encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        except FileNotFoundError:
            continue
    return digest.digest()


def launch_ide() -> subprocess.Popen:
    return subprocess.Popen(
        [require_tool("gleam"), "run"], cwd=APP, env=environment(),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=True,
    )


def dev() -> None:
    digest = files_digest(watch_files())
    while True:
        child = launch_ide()
        closed = threading.Event()

        def forward_output():
            for line in child.stdout:
                print(line, end="", flush=True)
                if "Campy window closed:" in line:
                    closed.set()

        reader = threading.Thread(target=forward_output, daemon=True)
        reader.start()
        restart = False
        try:
            while child.poll() is None:
                time.sleep(0.4)
                candidate = files_digest(watch_files())
                if candidate == digest:
                    continue
                digest = candidate
                print("Sources changed; rebuilding the IDE (Rust is unchanged).", flush=True)
                result = subprocess.run([require_tool("gleam"), "build"], cwd=APP, env=environment())
                if result.returncode == 0:
                    print("Build accepted; restarting the IDE.", flush=True)
                    restart = True
                    break
                print("Build rejected; keeping the running IDE.", flush=True)
        finally:
            stop_process(child)
            reader.join(timeout=2)
        if restart:
            continue
        if child.returncode or not closed.is_set():
            raise SystemExit(f"Development host exited unexpectedly (status {child.returncode}).")
        return


LAUNCHER = """#!/bin/sh
# Portable launcher for a packaged Campy app; requires only `erl` on PATH.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CAMPY_NIF_DIR="$BASE/campy_bridge/priv/native"
libs="$BASE/native-libs"
if [ -d "$libs" ]; then
    export LD_LIBRARY_PATH="$libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
exec "$BASE/entrypoint.sh" run "$@"
"""

SHIPMENT_README = """Campy Studio {version}
A portable build; unpack anywhere and run ./campy.

Requires only an Erlang/OTP 27+ installation with `erl` on PATH.
Development hot reload (F6) and generated codegen output are unavailable
here; unpack the source repository for the full studio workflow.
"""


def app_version() -> str:
    manifest = (APP / "gleam.toml").read_text(encoding="utf-8")
    match = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.MULTILINE)
    if not match:
        raise SystemExit("Cannot find the version in gleam/apps/campy_ide/gleam.toml")
    return match.group(1)


def export() -> None:
    """Package the IDE as a portable archive that runs with only Erlang/OTP."""
    stage_nif("release")
    shipment = APP / "build/erlang-shipment"
    shutil.rmtree(shipment, ignore_errors=True)
    command(["gleam", "export", "erlang-shipment"], cwd=APP)
    nif = shipment / "campy_bridge/priv/native" / nif_names()[1]
    if not nif.is_file():
        raise SystemExit("The shipment is missing the staged campy_bridge NIF.")
    launcher = shipment / "campy"
    launcher.write_text(LAUNCHER, encoding="utf-8")
    os.chmod(launcher, 0o755)
    (shipment / "README.txt").write_text(
        SHIPMENT_README.format(version=app_version()), encoding="utf-8"
    )
    # Ship the app's image assets; image paths resolve relative to the
    # launcher's working directory, which is the shipment root.
    assets = APP / "assets"
    if assets.is_dir():
        shutil.copytree(assets, shipment / "assets", dirs_exist_ok=True)
    # Bundle the curated native libraries the windowing stack may need
    # (for example libxkbcommon-x11), so target machines need not have them.
    local_libs = ROOT / "generated/native-deps/usr/lib64"
    if local_libs.is_dir():
        bundled = shipment / "native-libs"
        bundled.mkdir(exist_ok=True)
        for lib in sorted(local_libs.iterdir()):
            shutil.copy2(lib, bundled / lib.name)
    check_shipment(shipment)
    write_archive(shipment)


def check_shipment(shipment: Path) -> None:
    # Development-only variables (CAMPY_ROOT, reload signals) stay unset to
    # reproduce the launcher environment; the NIF directory points inside.
    env = {
        key: value for key, value in environment().items()
        if not key.startswith("CAMPY_")
    }
    env["CAMPY_NIF_DIR"] = str(shipment / "campy_bridge/priv/native")
    probe = ('io:format("campy nif ~s loaded~n", '
             '[integer_to_list(campy_bridge_ffi:protocol_version())]), halt().')
    ebins = sorted(str(path) for path in shipment.glob("*/ebin"))
    result = subprocess.run(
        [require_tool("erl"), "-noshell", "-eval", probe,
         *[path for ebin in ebins for path in ("-pa", ebin)]],
        env=env, capture_output=True, text=True,
    )
    if result.returncode or "campy nif" not in result.stdout:
        raise SystemExit(
            "Shipment NIF probe failed:\n"
            f"{result.stdout}{result.stderr}"
        )
    print(result.stdout.strip(), flush=True)


BUILD_APP_PROBE = """ProjectPath = unicode:characters_to_binary(os:getenv("CAMPY_BUILD_PROJECT")),
ModuleId = unicode:characters_to_binary(os:getenv("CAMPY_BUILD_MODULE")),
case campy_form@project:load(ProjectPath) of
  {ok, Project} ->
    case campy_broker:build(Project, ModuleId) of
      {ok, {Artifact, Manifest}} ->
        io:format("~s~n~s~n", [campy_manifest:to_summary(Manifest), Artifact]),
        halt(0);
      {error, Error} ->
        io:format(standard_error, "~s~n", [Error]),
        halt(1)
    end;
  {error, Error} ->
    io:format(standard_error, "~s~n", [Error]),
    halt(1)
end.
"""


def build_app(module_id: str) -> None:
    """Compile one project module into a broker artifact, end to end."""
    ebins = sorted(
        str(path) for path in BROKER.glob("build/dev/erlang/*/ebin")
    )
    if not ebins:
        raise SystemExit(
            f"Missing {BROKER.relative_to(ROOT)}/build; run `just build-gleam` first."
        )
    result = subprocess.run(
        [require_tool("erl"), "-noshell", "-eval", BUILD_APP_PROBE,
         *[path for ebin in ebins for path in ("-pa", ebin)]],
        cwd=ROOT, env={**environment(), "CAMPY_BUILD_PROJECT": str(PROJECT),
                      "CAMPY_BUILD_MODULE": module_id}, capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(
            (result.stdout + result.stderr).strip()
            or f"Broker build failed (status {result.returncode})."
        )
    print(result.stdout.strip(), flush=True)


def write_archive(shipment: Path) -> None:
    name = f"campy-studio-{app_version()}-{platform.system().lower()}-{platform.machine().lower()}"
    staged = shipment.parent / name
    shutil.rmtree(staged, ignore_errors=True)
    shutil.copytree(shipment, staged)
    DIST.mkdir(parents=True, exist_ok=True)
    archive = shutil.make_archive(str(DIST / name), "gztar", root_dir=staged.parent, base_dir=name)
    shutil.rmtree(staged, ignore_errors=True)
    size = Path(archive).stat().st_size / (1 << 20)
    print(f"Packaged {Path(archive).relative_to(ROOT)} ({size:.1f} MiB)", flush=True)


def main() -> None:
    action, *args = sys.argv[1:]
    if action == "doctor":
        for executable, flag in (
            ("cargo", "--version"), ("rustc", "--version"),
            ("gleam", "--version"), ("just", "--version"), (sys.executable, "--version"),
        ):
            command([executable, flag])
        command(["erl", "-noshell", "-eval",
                 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'])
    elif action == "stage-nif":
        stage_nif()
    elif action == "export":
        export()
    elif action == "gleam":
        gleam(args)
    elif action == "clean":
        clean()
    elif action == "run":
        command(["gleam", "run"], cwd=APP, expected="Campy window closed:")
    elif action == "smoke":
        command(["gleam", "run", "-m", "campy_bootstrap"], cwd=APP, expected="Campy bootstrap:")
    elif action == "gesture-probe":
        command(["gleam", "run", "-m", "campy_gesture_probe"], cwd=APP)
    elif action == "generate":
        command(["gleam", "run", "-m", "campy_codegen"], cwd=APP,
                expected="Generated and validated")
    elif action == "snapshot-ide":
        command(["gleam", "run", "-m", "campy_ide_snapshot"], cwd=APP,
                expected="IDE state transitions verified")
    elif action == "build-app":
        build_app(args[0] if args else "widgets")
    elif action == "dev":
        dev()
    else:
        raise SystemExit(f"Unknown action: {action}")


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from None
    except KeyboardInterrupt:
        raise SystemExit(130) from None

