#!/usr/bin/env python3
"""Small cross-toolchain runner; public commands live in the root justfile."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import platform
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
    for name in ("campy_ui", "campy_bridge", "campy_runtime", "campy_search_box", "campy_form", "campy_ccl")
] + [APP]
NATIVE = ROOT / "gleam/packages/campy_bridge/priv/native"
RELOAD = ROOT / "generated/reload.signal"


def environment() -> dict[str, str]:
    env = {
        **os.environ,
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
        child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(child.pid, signal.SIGKILL)
        else:
            child.kill()
        child.wait()


def command(args: list[str], cwd: Path = ROOT, expected: str | None = None) -> None:
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


def stage_nif() -> None:
    system = platform.system()
    names = {
        "Linux": ("libcampy_bridge.so", "campy_bridge.so"),
        "Darwin": ("libcampy_bridge.dylib", "campy_bridge.so"),
        "Windows": ("campy_bridge.dll", "campy_bridge.dll"),
    }
    source_name, target_name = names[system]
    target = Path(os.environ.get("CARGO_TARGET_DIR", str(ROOT / "rust/target")))
    if not target.is_absolute():
        target = ROOT / target
    source = target / "debug" / source_name
    NATIVE.mkdir(parents=True, exist_ok=True)
    destination = NATIVE / target_name
    # Never overwrite a shared library mapped into a running BEAM VM.
    temporary = destination.with_suffix(destination.suffix + ".new")
    shutil.copy2(source, temporary)
    os.replace(temporary, destination)
    print(f"Staged {destination.relative_to(ROOT)}", flush=True)


def gleam(args: list[str]) -> None:
    for package in PACKAGES:
        command(["gleam", *args], cwd=package,
                expected="passed, no failures" if args[0] == "test" else None)


def watch_files() -> list[Path]:
    roots = [
        ROOT / "gleam/apps/campy_ide/src",
        ROOT / "gleam/packages/campy_form/src",
        ROOT / "gleam/packages/campy_ui/src",
    ]
    files: list[Path] = []
    for root in roots:
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
        ["gleam", "run"], cwd=APP, env={**environment(), "CAMPY_WATCH": "1"},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=True,
    )


def dev() -> None:
    files = watch_files()
    digest = files_digest(files)
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
                candidate = files_digest(files)
                if candidate == digest:
                    continue
                digest = candidate
                print("Sources changed; rebuilding the IDE (Rust is unchanged).", flush=True)
                result = subprocess.run(["gleam", "build"], cwd=APP, env=environment())
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


def main() -> None:
    action, *args = sys.argv[1:]
    if action == "doctor":
        for executable, flag in (
            ("cargo", "--version"), ("rustc", "--version"),
            ("gleam", "--version"), ("just", "--version"), ("python3", "--version"),
        ):
            command([executable, flag])
        command(["erl", "-noshell", "-eval",
                 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'])
    elif action == "stage-nif":
        stage_nif()
    elif action == "gleam":
        gleam(args)
    elif action == "run":
        command(["gleam", "run"], cwd=APP, expected="Campy window closed:")
    elif action == "smoke":
        command(["gleam", "run", "-m", "campy_bootstrap"], cwd=APP, expected="Campy bootstrap:")
    elif action == "generate":
        command(["gleam", "run", "-m", "campy_codegen"], cwd=APP,
                expected="Generated and validated")
    elif action == "snapshot-ide":
        command(["gleam", "run", "-m", "campy_ide_snapshot"], cwd=APP,
                expected="IDE snapshots written")
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

