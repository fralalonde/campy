set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Check the toolchain, OTP release, and the wx application.
doctor:
    python scripts/workspace.py doctor

# Open the IDE shell on examples/demo (set CAMPY_PROJECT for another project).
run:
    python scripts/workspace.py run

# Scripted IDE mount/open/save/close; needs a display.
smoke:
    python scripts/workspace.py smoke

# Build every package and the IDE app.
build:
    python scripts/workspace.py gleam build

fmt:
    python scripts/workspace.py gleam format

fmt-check:
    python scripts/workspace.py gleam format --check

test:
    python scripts/workspace.py gleam test

check: fmt-check test

# Remove Gleam build output and generated files.
clean:
    python scripts/workspace.py clean
