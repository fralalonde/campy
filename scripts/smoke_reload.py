#!/usr/bin/env python3
"""Exercise one running VM, success, failure, recovery, and unchanged native code.

Run through `just smoke-reload`. Temporarily edits the search-box fixture, then
restores it even on failure. The first slice tests descriptions, not live widgets.
"""

import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "gleam/packages/campy_search_box/src/campy_search_box.gleam"
NATIVE = ROOT / "gleam/packages/campy_bridge/priv/native/campy_bridge.so"
LOG = ROOT / "generated/reload-smoke.log"


def main():
    if sys.platform != "linux":
        raise SystemExit("This first process-lifecycle smoke test targets Linux.")
    original = SOURCE.read_text()
    native_hash = hashlib.sha256(NATIVE.read_bytes()).digest()
    LOG.parent.mkdir(exist_ok=True)
    with LOG.open("w") as output:
        child = subprocess.Popen(
            [sys.executable, "scripts/workspace.py", "dev"],
            cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
            start_new_session=True, env={**os.environ, "CAMPY_HEADLESS": "1"},
        )

        def wait_for(text):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                content = LOG.read_text()
                if text in content:
                    return
                if child.poll() is not None:
                    raise AssertionError(f"Host stopped before {text!r}:\n{content}")
                time.sleep(0.1)
            raise AssertionError(f"Timed out waiting for {text!r}:\n{LOG.read_text()}")

        try:
            wait_for("Watching search-box builds")
            SOURCE.write_text(original.replace('TextLiteral("Search")', 'TextLiteral("Find")'))
            wait_for("Accepted UI generation 2")
            SOURCE.write_text(original.replace('id: "query-input"', 'id: "9-invalid"'))
            wait_for("Reload rejected; keeping last accepted UI")
            SOURCE.write_text(original + "\nthis is deliberately invalid Gleam\n")
            wait_for("Build rejected; running host retains its accepted UI.")
            SOURCE.write_text(original)
            wait_for("Accepted UI generation 3")
            assert LOG.read_text().count("Campy bootstrap:") == 1, "VM restarted"
            assert hashlib.sha256(NATIVE.read_bytes()).digest() == native_hash, "NIF changed"
            print("Reload smoke passed: same host, accepted update, rejected UI/code, recovery, unchanged NIF.")
        finally:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            child.wait(timeout=10)
            SOURCE.write_text(original)
            # Restore on-disk BEAM code as well, without touching Rust.
            subprocess.run(
                ["gleam", "build"], cwd=ROOT / "gleam/apps/campy_ide", check=True,
            )


if __name__ == "__main__":
    main()

