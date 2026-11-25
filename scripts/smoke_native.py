#!/usr/bin/env python
"""Exercise the native NIF with zgui's headless input/lifecycle driver."""
import subprocess
import sys

from workspace import APP, ROOT, environment, require_tool, stop_process


def main():
    if sys.platform not in ("linux", "win32"):
        raise SystemExit("Native sessions currently support Linux and Windows only")
    if len(sys.argv) > 1:
        raise SystemExit("The protocol-v2 smoke driver is headless; no backend argument is needed")
    log = ROOT / "generated/native-smoke.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as output:
        process = subprocess.Popen([require_tool("gleam"), "run", "-m", "campy_native_smoke"], cwd=APP,
                                   env=environment(), stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=35)
            content = log.read_text()
            if (process.returncode != 0 or "NATIVE_SMOKE_PASSED" not in content
                    or "panicked at" in content or "UI thread panicked" in content):
                raise SystemExit(content or f"Native smoke exited with status {process.returncode}")
            print(content)
            print(f"Native headless smoke passed; log: {log}")
        finally:
            stop_process(process)


if __name__ == "__main__":
    main()
