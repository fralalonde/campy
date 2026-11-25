#!/usr/bin/env python3
"""Exercise one running VM, success, failure, recovery, and unchanged native code.

Run through `just smoke-reload`. Temporarily edits the search-box fixture, then
restores it even on failure. The first slice tests descriptions, not live widgets.
"""

import hashlib
import subprocess
import time

from workspace import APP, NATIVE, RELOAD, ROOT, environment, nif_names, require_tool, stop_process

SOURCE = ROOT / "gleam/packages/campy_search_box/src/campy_search_box.gleam"
LOG = ROOT / "generated/reload-smoke.log"


def main():
    original_bytes = SOURCE.read_bytes()
    original = original_bytes.decode("utf-8")
    native = NATIVE / nif_names()[1]
    native_hash = hashlib.sha256(native.read_bytes()).digest()
    previous_signal = RELOAD.read_bytes() if RELOAD.exists() else None
    gleam = require_tool("gleam")
    LOG.parent.mkdir(exist_ok=True)
    with LOG.open("w") as output:
        child = subprocess.Popen(
            [gleam, "run", "-m", "campy_bootstrap"],
            cwd=APP, stdout=output, stderr=subprocess.STDOUT,
            start_new_session=True, env={**environment(), "CAMPY_WATCH": "1"},
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

        def rebuild(source, accepted=True):
            SOURCE.write_bytes(source.encode("utf-8"))
            result = subprocess.run([gleam, "build"], cwd=APP, env=environment(),
                                    stdout=output, stderr=subprocess.STDOUT)
            if (result.returncode == 0) != accepted:
                raise AssertionError(f"Unexpected build status {result.returncode}:\n{LOG.read_text()}")
            if accepted:
                RELOAD.write_text(str(time.monotonic_ns()))

        try:
            wait_for("Watching search-box builds")
            rebuild(original.replace('TextLiteral("Search")', 'TextLiteral("Find")'))
            wait_for("Accepted UI generation 2")
            rebuild(original.replace('id: "query-input"', 'id: "9-invalid"'))
            wait_for("Reload rejected; keeping last accepted UI")
            rebuild(original + "\nthis is deliberately invalid Gleam\n", accepted=False)
            assert child.poll() is None, "Rejected build stopped the host"
            rebuild(original)
            wait_for("Accepted UI generation 3")
            assert LOG.read_text().count("Campy bootstrap:") == 1, "VM restarted"
            assert hashlib.sha256(native.read_bytes()).digest() == native_hash, "NIF changed"
            print("Reload smoke passed: same host, accepted update, rejected UI/code, recovery, unchanged NIF.")
        finally:
            try:
                stop_process(child)
            finally:
                SOURCE.write_bytes(original_bytes)
                if previous_signal is None:
                    RELOAD.unlink(missing_ok=True)
                else:
                    RELOAD.write_bytes(previous_signal)
                # Restore on-disk BEAM code as well, without touching Rust.
                subprocess.run([gleam, "build"], cwd=APP, env=environment(), check=True)


if __name__ == "__main__":
    main()

