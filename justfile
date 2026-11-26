set shell := ["bash", "-euo", "pipefail", "-c"]

# Recipes run from whatever shell the developer has. A rustup-managed `cargo`
# on PATH does not imply the Gleam/Erlang shims are there: asdf keeps those in
# `~/.asdf/shims`, which a login shell or an editor's task runner may lack. The
# scripts also resolve tools themselves, so this is the shortest path for the
# recipes that exec a binary directly (`scripts/cargo.sh`).
export PATH := home_directory() / ".asdf" / "shims" \
  + ":" + home_directory() / ".cargo/bin" \
  + ":" + home_directory() / ".local/bin" \
  + ":" + env_var_or_default("PATH", "")

default:
    @just --list

# The live session test, which opens real windows: opt in explicitly.
test-live:
    CAMPY_LIVE_TESTS=1 python scripts/workspace.py gleam test

# Check the locally installed toolchain.
doctor:
    python scripts/workspace.py doctor

build-rust:
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked

build-rust-release:
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked --release

stage-nif: build-rust
    python scripts/workspace.py stage-nif

build-gleam:
    python scripts/workspace.py gleam build

# Build both subroots and install the development NIF into the bridge package.
build: stage-nif build-gleam

# Package the IDE as a portable archive for distribution (runs with only OTP).
# Leaves a release NIF staged; `just build` restores the development build.
package: build-rust-release
    python scripts/workspace.py export

# Remove Rust/Gleam build artifacts and the staged development NIF.
clean:
    ./scripts/cargo.sh clean --manifest-path rust/Cargo.toml
    python scripts/workspace.py clean

# Open the native Gleam/BEAM IDE host (Linux or Windows Winit).
run: build
    python scripts/workspace.py run

# Rebuild and restart the IDE after successful Gleam source changes.
dev: build
    python scripts/workspace.py dev

# Compile a designed module into a versioned broker artifact (default: `widgets`).
build-app module="widgets": build-gleam
    python scripts/workspace.py build-app {{module}}

# Check the Canora sample's handlers and regenerate the project the IDE loads
# at runtime. Samples are not part of `check`: Campy never depends on them.
demo:
    cd demo/canora && gleam format --check && gleam test
    cd demo/canora && CAMPY_ROOT="$(cd ../.. && pwd)" gleam run -m canora_project

# Write projects/campy-dev.campy: campy's own sources as external modules.
dogfood:
    python scripts/make_dogfood.py

# Emit the legacy search-box Slint fixture (not used by the native renderer).
generate: build
    python scripts/workspace.py generate

# Verify IDE state transitions against a live renderer (opens a window).
snapshot-ide: build
    python scripts/workspace.py snapshot-ide

# The Rust half of the suite. The ui-testing feature builds
# the headless zgui driver the bridge integration test rides.
test-rust:
    ./scripts/cargo.sh test --manifest-path rust/Cargo.toml --locked --features campy-renderer/ui-testing

# Full suite with the development NIF staged for Gleam tests.
test: stage-nif
    just test-rust
    python scripts/workspace.py gleam test

fmt:
    ./scripts/cargo.sh fmt --manifest-path rust/Cargo.toml --all
    python scripts/workspace.py gleam format

fmt-check:
    ./scripts/cargo.sh fmt --manifest-path rust/Cargo.toml --all -- --check
    ./scripts/cargo.sh clippy --manifest-path rust/Cargo.toml --locked --all-targets
    python scripts/workspace.py gleam format --check

test-scripts:
    python -m unittest discover -s scripts -p 'test_*.py'

check: fmt-check test-scripts test


# Headless reload smoke; temporarily edits and restores the search-box fixture.
smoke-reload: build
    python scripts/smoke_reload.py

# Headless definition/NIF bootstrap for CI and display-free verification.
smoke: build
    python scripts/workspace.py smoke

# Native NIF input/lifecycle test through the headless platform driver.
smoke-native: build-gleam
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked --features campy-bridge/ui-testing
    python scripts/workspace.py stage-nif
    python scripts/smoke_native.py

# Native drag-gesture probe: verifies the designer's hybrid drag contract
# (click selects, drag from a selection moves, drag from empty space or an
# unselected control draws the marquee) with injected pointer input.
probe-gestures:
    ./scripts/cargo.sh build --manifest-path rust/Cargo.toml --locked --features campy-bridge/ui-testing
    python scripts/workspace.py stage-nif
    python scripts/workspace.py gesture-probe
