#!/usr/bin/env python
"""Cross-package runner; public commands live in the root justfile."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IDE = ROOT / "gleam/apps/campy_ide_wx"
DEMO = ROOT / "examples/demo"
GENERATED = ROOT / "generated"

PACKAGES = [
    ROOT / "gleam/packages" / name
    for name in (
        "campy_view",
        "campy_wx",
        "campy_project",
        "campy_ide_model",
        "campy_design",
        "campy_catalog",
        "campy_manifest",
        "campy_app",
        "campy_appgen",
        "campy_source",
    )
] + [IDE]


def environment() -> dict[str, str]:
    env = {**os.environ, "CAMPY_ROOT": str(ROOT)}
    env.setdefault("CAMPY_PROJECT", str(DEMO))
    return env


def command(args: list[str], cwd: Path = ROOT) -> None:
    subprocess.run(args, cwd=cwd, env=environment(), check=True)


def gleam(args: list[str]) -> None:
    for package in PACKAGES:
        command(["gleam", *args], cwd=package)


def clean() -> None:
    for package in PACKAGES:
        subprocess.run(["gleam", "clean"], cwd=package, env=environment())
    for entry in GENERATED.glob("*"):
        if entry.name == ".gitkeep":
            continue
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def doctor() -> None:
    for args in (
        ["gleam", "--version"],
        ["just", "--version"],
        [sys.executable, "--version"],
        [
            "erl",
            "-noshell",
            "-eval",
            'io:format("OTP ~s, wx ~s~n", '
            "[erlang:system_info(otp_release), code:lib_dir(wx)]), halt().",
        ],
    ):
        command(args)


def main() -> None:
    action, *rest = sys.argv[1:]
    if action == "doctor":
        doctor()
    elif action == "gleam":
        gleam(rest)
    elif action == "clean":
        clean()
    elif action == "run":
        command(["gleam", "run"], cwd=IDE)
    elif action == "smoke":
        subprocess.run(
            ["gleam", "run"], cwd=IDE, env={**environment(), "CAMPY_WX_SMOKE": "1"},
            check=True,
        )
    else:
        raise SystemExit(f"Unknown action: {action}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from None
