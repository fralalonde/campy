#!/usr/bin/env python
"""Render real native windows; dispatch input through a test-only Slint adapter."""
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from workspace import APP, environment


def main():
    if sys.platform not in ("linux", "win32"):
        raise SystemExit("Native sessions currently support Linux and Windows only")
    backend = sys.argv[1] if len(sys.argv) > 1 else "auto"
    if backend not in ("auto", "x11"):
        raise SystemExit("Backend must be auto or x11")
    if backend == "x11" and sys.platform != "linux":
        raise SystemExit("The x11 backend is available on Linux only")
    env = environment()
    if backend == "x11":
        env.pop("WAYLAND_DISPLAY", None)
    log = ROOT / "generated/native-smoke.log"
    snapshot = ROOT / "generated/native-smoke.png"
    snapshot.unlink(missing_ok=True)
    with log.open("w") as output:
        process = subprocess.Popen(["gleam", "run", "-m", "campy_native_smoke"], cwd=APP,
                                   env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=35)
            content = log.read_text()
            assert process.returncode == 0 and "NATIVE_SMOKE_PASSED" in content, content
            width, height = struct.unpack(">II", snapshot.read_bytes()[16:24])
            assert (width, height) == (640, 140), (width, height)
            print(content)
            print(f"Native smoke passed ({backend}); rendered snapshot: {snapshot}")
        finally:
            if process.poll() is None:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGTERM)
                else:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
